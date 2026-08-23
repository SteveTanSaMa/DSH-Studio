//
//  RuntimeUpdateCoordinator+Activation.swift
//  DSH Studio
//

import DeepSeekLogging
import Foundation

extension RuntimeUpdateCoordinator {
    func prepareUpdate(
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

    func activatePreparedUpdate(
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

    func activateLegacyUpdate(
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
}
