//
//  RuntimeUpdateCoordinator.swift
//  DSH Studio
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
    weak var runtime: RuntimeManager?
    let updater: any RuntimeUpdating
    var operationInProgress = false

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
}
