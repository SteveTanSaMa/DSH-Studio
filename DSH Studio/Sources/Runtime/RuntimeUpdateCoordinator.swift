//
//  RuntimeUpdateCoordinator.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import DeepSeekLogging
import Foundation

/// Coordinates an online Runtime replacement with the Harness process.
///
/// RuntimeProvisioner owns files and directory atomicity. This type owns the
/// app-level sequence: stop the child process, install the candidate, verify
/// that it can become ready, and restore the previous installation if it
/// cannot. Keeping those responsibilities separate makes file operations easy
/// to test without launching a real Harness process.
@MainActor
public final class RuntimeUpdateCoordinator {
    private weak var runtime: RuntimeManager?
    private let updater: any RuntimeUpdating
    private var operationInProgress = false

    public var isBusy: Bool {
        operationInProgress
    }

    init(runtime: RuntimeManager, updater: any RuntimeUpdating) {
        self.runtime = runtime
        self.updater = updater
    }

    public func checkVersion() -> RuntimeVersionStatus {
        let status = updater.versionStatus()
        runtime?.setRuntimeVersionStatus(status)
        return status
    }

    public func update() async throws {
        try await update(targetProfile: nil)
    }

    /// Downloads and verifies an available candidate without stopping the
    /// current Harness process. Activation remains a separate explicit step.
    public func prepare() async throws {
        guard let runtime else {
            throw RuntimeUpdateError.unavailable
        }
        guard !operationInProgress else {
            throw RuntimeUpdateError.updateFailed("Runtime 当前正在执行其他操作")
        }
        guard runtime.state != .provisioning,
              runtime.state != .updating,
              runtime.state != .rollingBack else {
            throw RuntimeUpdateError.updateFailed("Runtime 当前正在执行其他操作")
        }

        operationInProgress = true
        defer { operationInProgress = false }

        let status = checkVersion()
        if status.updatePrepared {
            return
        }
        guard status.kind == .updateAvailable,
              let candidateUpdater = updater as? any RuntimeCandidateUpdating else {
            switch status.kind {
            case .current, .newerInstalled:
                throw RuntimeUpdateError.noUpdateAvailable
            case .updateBlocked:
                throw RuntimeUpdateError.runtimeVersionConflict
            default:
                throw RuntimeUpdateError.unavailable
            }
        }
        try await prepareUpdate(
            runtime: runtime,
            updater: candidateUpdater,
            status: status
        )
    }

    /// Activates a prepared Runtime against an explicitly selected data
    /// profile. The first call still only prepares the candidate; the second
    /// call performs the profile switch and activation together.
    public func update(using profile: RuntimeDataProfile) async throws {
        try await update(targetProfile: profile)
    }

    private func update(targetProfile: RuntimeDataProfile?) async throws {
        guard let runtime else {
            throw RuntimeUpdateError.unavailable
        }
        guard !operationInProgress else {
            throw RuntimeUpdateError.updateFailed("Runtime 当前正在执行其他操作")
        }
        guard runtime.state != .provisioning,
              runtime.state != .updating,
              runtime.state != .rollingBack else {
            throw RuntimeUpdateError.updateFailed("Runtime 当前正在执行其他操作")
        }

        operationInProgress = true
        defer { operationInProgress = false }

        let status = checkVersion()
        guard status.kind == .updateAvailable || status.kind == .updatePrepared else {
            if status.kind == .updateBlocked {
                throw RuntimeUpdateError.runtimeVersionConflict
            }
            throw RuntimeUpdateError.noUpdateAvailable
        }

        if let candidateUpdater = updater as? any RuntimeCandidateUpdating {
            if status.updatePrepared {
                try await activatePreparedUpdate(
                    runtime: runtime,
                    updater: candidateUpdater,
                    status: status,
                    targetProfile: targetProfile
                )
            } else {
                try await prepareUpdate(
                    runtime: runtime,
                    updater: candidateUpdater,
                    status: status
                )
            }
            return
        }

        try await activateLegacyUpdate(runtime: runtime, status: status)
    }

    private func prepareUpdate(
        runtime: RuntimeManager,
        updater: any RuntimeCandidateUpdating,
        status: RuntimeVersionStatus
    ) async throws {
        guard status.kind == .updateAvailable else {
            throw RuntimeUpdateError.noUpdateAvailable
        }
        runtime.logs.log(component: "Runtime", level: "info", message: "Runtime candidate preparation started")
        do {
            _ = try await updater.prepareUpdate()
            runtime.refreshRuntimeMetadata()
            runtime.logs.log(component: "Runtime", level: "info", message: "Runtime candidate prepared")
        } catch {
            runtime.logs.log(
                component: "Runtime",
                level: "error",
                message: "Runtime candidate preparation failed: \(LogRedactor.redact(error.localizedDescription))"
            )
            throw RuntimeUpdateError.updateFailed(LogRedactor.redact(error.localizedDescription))
        }
    }

    private func activatePreparedUpdate(
        runtime: RuntimeManager,
        updater: any RuntimeCandidateUpdating,
        status: RuntimeVersionStatus,
        targetProfile: RuntimeDataProfile? = nil
    ) async throws {
        guard status.updatePrepared else {
            throw RuntimeUpdateError.noUpdateAvailable
        }

        let activationProfile: RuntimeDataProfile?
        if let targetProfile {
            try validateDataProfile(
                targetProfile,
                against: status.available.dataFormat,
                store: runtime.dataProfileStore
            )
            activationProfile = targetProfile
        } else {
            activationProfile = try automaticDataProfileIfNeeded(
                runtime: runtime,
                status: status
            )
        }

        let shouldResume = shouldResume(after: runtime.state)
        let originalProfile = runtime.activeDataProfile
        let originalHomeURL = runtime.configuration.dshHome
        if shouldResume {
            await runtime.stop()
        }
        if let activationProfile {
            do {
                try runtime.selectDataProfile(activationProfile)
            } catch {
                runtime.configuration.dshHome = originalHomeURL
                throw RuntimeUpdateError.updateFailed(LogRedactor.redact(error.localizedDescription))
            }
        }
        runtime.setRuntimeOperationState(.updating)
        runtime.logs.log(component: "Runtime", level: "info", message: "Runtime update started")

        do {
            let result = try updater.activatePreparedUpdate()
            runtime.applyRuntimeResult(result)
        } catch {
            runtime.logs.log(
                component: "Runtime",
                level: "error",
                message: "Runtime update failed: \(LogRedactor.redact(error.localizedDescription))"
            )
            restoreDataProfile(
                runtime: runtime,
                profile: originalProfile,
                homeURL: originalHomeURL
            )
            await relaunchOldRuntime(runtime, shouldResume: shouldResume)
            throw RuntimeUpdateError.updateFailed(LogRedactor.redact(error.localizedDescription))
        }

        guard await verifyActivatedRuntime(runtime, keepRunning: shouldResume) else {
            runtime.forceStop()
            runtime.logs.log(
                component: "Runtime",
                level: "warn",
                message: "updated Runtime failed to become ready; rolling back"
            )
            do {
                let result = try updater.rollback()
                restoreDataProfile(
                    runtime: runtime,
                    profile: originalProfile,
                    homeURL: originalHomeURL
                )
                runtime.applyRuntimeResult(result)
            } catch {
                throw RuntimeUpdateError.rollbackFailed(
                    LogRedactor.redact(error.localizedDescription)
                )
            }

            guard shouldResume else {
                runtime.setRuntimeOperationState(.terminated)
                runtime.refreshRuntimeMetadata()
                throw RuntimeUpdateError.updateFailed("新 Runtime 无法启动，已自动回滚")
            }

            runtime.setRuntimeOperationState(.terminated)
            runtime.start()
            guard await waitUntilReady(runtime) else {
                runtime.forceStop()
                throw RuntimeUpdateError.rollbackFailed("回滚后的 Runtime 无法启动")
            }
            throw RuntimeUpdateError.updateFailed("新 Runtime 无法启动，已自动回滚")
        }

        runtime.refreshRuntimeMetadata()
        runtime.logs.log(component: "Runtime", level: "info", message: "Runtime update completed")
    }

    private func activateLegacyUpdate(
        runtime: RuntimeManager,
        status: RuntimeVersionStatus
    ) async throws {
        // The legacy updater has no candidate directory. Preserve its old
        // behavior only for test/development implementations; production
        // RuntimeProvisioner uses the two-phase path above.
        if status.installed != nil {
            try validateCompatibility(status.dataCompatibility)
        }

        let shouldResume = shouldResume(after: runtime.state)
        if shouldResume {
            await runtime.stop()
        }
        runtime.setRuntimeOperationState(.updating)
        runtime.logs.log(component: "Runtime", level: "info", message: "Runtime update started")

        do {
            let result = try await updater.update()
            runtime.applyRuntimeResult(result)
        } catch {
            runtime.logs.log(
                component: "Runtime",
                level: "error",
                message: "Runtime update failed: \(LogRedactor.redact(error.localizedDescription))"
            )
            await relaunchOldRuntime(runtime, shouldResume: shouldResume)
            throw RuntimeUpdateError.updateFailed(LogRedactor.redact(error.localizedDescription))
        }

        try await finishActivatedUpdate(runtime: runtime, shouldResume: shouldResume)
    }

    private func finishActivatedUpdate(
        runtime: RuntimeManager,
        shouldResume: Bool
    ) async throws {
        guard await verifyActivatedRuntime(runtime, keepRunning: shouldResume) else {
            runtime.forceStop()
            runtime.logs.log(
                component: "Runtime",
                level: "warn",
                message: "updated Runtime failed to become ready; rolling back"
            )
            do {
                let result = try updater.rollback()
                runtime.applyRuntimeResult(result)
            } catch {
                throw RuntimeUpdateError.rollbackFailed(
                    LogRedactor.redact(error.localizedDescription)
                )
            }

            guard shouldResume else {
                runtime.setRuntimeOperationState(.terminated)
                runtime.refreshRuntimeMetadata()
                throw RuntimeUpdateError.updateFailed("新 Runtime 无法启动，已自动回滚")
            }

            runtime.setRuntimeOperationState(.terminated)
            runtime.start()
            guard await waitUntilReady(runtime) else {
                runtime.forceStop()
                throw RuntimeUpdateError.rollbackFailed("回滚后的 Runtime 无法启动")
            }
            throw RuntimeUpdateError.updateFailed("新 Runtime 无法启动，已自动回滚")
        }

        runtime.refreshRuntimeMetadata()
        runtime.logs.log(component: "Runtime", level: "info", message: "Runtime update completed")
    }

    public func rollback() async throws {
        guard let runtime else {
            throw RuntimeUpdateError.unavailable
        }
        guard !operationInProgress else {
            throw RuntimeUpdateError.rollbackFailed("Runtime 当前正在执行其他操作")
        }
        guard runtime.state != .provisioning,
              runtime.state != .updating,
              runtime.state != .rollingBack else {
            throw RuntimeUpdateError.rollbackFailed("Runtime 当前正在执行其他操作")
        }

        operationInProgress = true
        defer { operationInProgress = false }

        let status = checkVersion()
        guard status.rollbackAvailable else {
            throw RuntimeUpdateError.rollbackUnavailable
        }

        let shouldResume = shouldResume(after: runtime.state)
        let originalProfile = runtime.activeDataProfile
        let originalHomeURL = runtime.configuration.dshHome
        let rollbackProfile = runtime.dataProfileStore?.previousProfile() ?? originalProfile
        if shouldResume {
            await runtime.stop()
        }
        runtime.setRuntimeOperationState(.rollingBack)
        runtime.logs.log(component: "Runtime", level: "info", message: "Runtime rollback started")

        do {
            let result = try updater.rollback()
            runtime.applyRuntimeResult(result)
            runtime.setRuntimeOperationState(.terminated)
            if let rollbackProfile,
               rollbackProfile.homeURL.standardizedFileURL != originalHomeURL.standardizedFileURL {
                try runtime.selectDataProfile(rollbackProfile)
            }
        } catch {
            restoreDataProfile(
                runtime: runtime,
                profile: originalProfile,
                homeURL: originalHomeURL
            )
            await relaunchOldRuntime(runtime, shouldResume: shouldResume)
            throw RuntimeUpdateError.rollbackFailed(LogRedactor.redact(error.localizedDescription))
        }

        guard await verifyActivatedRuntime(runtime, keepRunning: shouldResume) else {
            runtime.forceStop()
            do {
                let result = try updater.rollback()
                restoreDataProfile(
                    runtime: runtime,
                    profile: originalProfile,
                    homeURL: originalHomeURL
                )
                runtime.applyRuntimeResult(result)
            } catch {
                throw RuntimeUpdateError.rollbackFailed(
                    "回滚后的 Runtime 无法启动，且无法恢复原 Runtime：\(LogRedactor.redact(error.localizedDescription))"
                )
            }

            guard shouldResume else {
                runtime.setRuntimeOperationState(.terminated)
                runtime.refreshRuntimeMetadata()
                throw RuntimeUpdateError.rollbackFailed("回滚后的 Runtime 无法启动，已恢复原 Runtime")
            }

            runtime.setRuntimeOperationState(.terminated)
            runtime.start()
            guard await waitUntilReady(runtime) else {
                runtime.forceStop()
                throw RuntimeUpdateError.rollbackFailed("回滚后的 Runtime 无法启动，已恢复原 Runtime")
            }
            throw RuntimeUpdateError.rollbackFailed("回滚后的 Runtime 无法启动，已恢复原 Runtime")
        }
        runtime.refreshRuntimeMetadata()
        runtime.logs.log(component: "Runtime", level: "info", message: "Runtime rollback completed")
    }

    private func shouldResume(after state: RuntimeState) -> Bool {
        switch state {
        case .idle, .terminated:
            return false
        case .provisioning, .updating, .rollingBack:
            return false
        case .launching, .starting, .ready, .failed, .crashed, .stopping:
            return true
        }
    }

    private func verifyActivatedRuntime(
        _ runtime: RuntimeManager,
        keepRunning: Bool
    ) async -> Bool {
        runtime.setRuntimeOperationState(.terminated)
        runtime.start()
        guard await waitUntilReady(runtime) else { return false }
        if !keepRunning {
            await runtime.stop()
        }
        return true
    }

    private func validateCompatibility(_ compatibility: RuntimeDataCompatibility) throws {
        switch compatibility {
        case .compatible:
            return
        case .unknown:
            throw RuntimeUpdateError.dataCompatibilityUnknown
        case .incompatible:
            throw RuntimeUpdateError.dataIncompatible
        case .requiresMigration:
            throw RuntimeUpdateError.dataMigrationRequired
        }
    }

    /// Data format changes are an implementation detail of Runtime updates.
    /// When the current profile cannot be reused, create an isolated profile
    /// automatically and leave the old data directory untouched.
    private func automaticDataProfileIfNeeded(
        runtime: RuntimeManager,
        status: RuntimeVersionStatus
    ) throws -> RuntimeDataProfile? {
        switch status.dataCompatibility {
        case .compatible:
            return nil
        case .incompatible, .requiresMigration, .unknown:
            guard let dataFormat = status.available.dataFormat,
                  let store = runtime.dataProfileStore else {
                try validateCompatibility(status.dataCompatibility)
                return nil
            }
            let profile = try store.createProfile(
                name: "DeepSeek Harness " + status.available.harnessVersion,
                dataFormatID: dataFormat.id
            )
            try validateDataProfile(
                profile,
                against: status.available.dataFormat,
                store: store
            )
            runtime.logs.log(
                component: "Runtime",
                level: "info",
                message: "created an isolated data profile for Harness " + status.available.harnessVersion
            )
            return profile
        }
    }

    private func validateDataProfile(
        _ profile: RuntimeDataProfile,
        against runtimeFormat: RuntimeDataFormatDescriptor?,
        store: RuntimeDataProfileStore?
    ) throws {
        guard profile.isValid else {
            throw RuntimeUpdateError.updateFailed("目标数据环境描述无效")
        }
        guard let runtimeFormat else {
            if profile.dataFormatID == nil,
               store?.isDataHomeEmpty(profile.homeURL) == true {
                return
            }
            throw RuntimeUpdateError.dataCompatibilityUnknown
        }
        if let profileFormatID = profile.dataFormatID {
            try validateCompatibility(runtimeFormat.compatibility(with: profileFormatID))
        } else if store?.isDataHomeEmpty(profile.homeURL) == true {
            return
        } else {
            throw RuntimeUpdateError.dataCompatibilityUnknown
        }
    }

    private func restoreDataProfile(
        runtime: RuntimeManager,
        profile: RuntimeDataProfile?,
        homeURL: URL
    ) {
        // A failed activation reaches this helper while the coordinator still
        // marks the manager as updating. The child process is already stopped,
        // so make the stopped state explicit before restoring the old profile.
        runtime.setRuntimeOperationState(.terminated)
        guard let profile else {
            runtime.configuration.dshHome = homeURL
            runtime.activeDataProfile = nil
            if let selector = runtime.runtimeUpdater as? any RuntimeDataProfileSelecting {
                selector.setDataProfileID(nil)
            }
            runtime.runtimeVersionStatus = runtime.runtimeUpdater?.versionStatus()
            return
        }
        try? runtime.selectDataProfile(profile)
    }

    private func relaunchOldRuntime(_ runtime: RuntimeManager, shouldResume: Bool) async {
        guard shouldResume else {
            runtime.setRuntimeOperationState(.terminated)
            return
        }
        runtime.setRuntimeOperationState(.terminated)
        runtime.start()
        _ = await waitUntilReady(runtime)
    }

    private func waitUntilReady(_ runtime: RuntimeManager) async -> Bool {
        let timeout = max(runtime.configuration.startupTimeout + 1, 2)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch runtime.state {
            case .ready:
                return true
            case .failed, .crashed:
                return false
            default:
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        return runtime.state == .ready
    }
}
