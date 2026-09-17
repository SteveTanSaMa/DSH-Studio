//
//  RuntimeUpdateCoordinator+Activation.swift
//  DSH Studio
//

import DeepSeekLogging
import Foundation

/// Two-phase update execution: prepare the candidate, then activate it.
extension RuntimeUpdateCoordinator {
    /// Downloads and verifies the candidate and publishes it as prepared.
    ///
    /// The running Runtime is left alone: the candidate lands in its own root and only
    /// ``activatePreparedUpdate(...)`` makes it authoritative. A failure leaves the
    /// active installation and the selected data profile untouched.
    ///
    /// - Parameters:
    ///   - runtime: Manager whose state is updated around the work.
    ///   - updater: Provisioner that performs the download and verification.
    ///   - status: Version comparison the preparation was decided from.
    /// - Throws: ``RuntimeUpdateError`` when the candidate cannot be prepared.
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

    /// Activates the prepared candidate against an optional data profile.
    ///
    /// The current process is stopped first; if the candidate does not become ready,
    /// the previous installation and the previous data profile are restored before the
    /// error is rethrown.
    ///
    /// - Parameters:
    ///   - runtime: Manager whose process is stopped and restarted.
    ///   - updater: Provisioner that activates the candidate.
    ///   - status: Version comparison describing the prepared candidate.
    ///   - targetProfile: Data profile to switch to, or `nil` to keep the current one.
    /// - Throws: ``RuntimeUpdateError`` when activation or the restart fails.
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

    /// Activates an update for an updater that has no separate prepare step.
    ///
    /// Used for installers that replace the Runtime in one call, so there is no
    /// prepared candidate to fall back on.
    ///
    /// - Parameters:
    ///   - runtime: Manager whose process is stopped and restarted.
    ///   - status: Version comparison that reported the update.
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
