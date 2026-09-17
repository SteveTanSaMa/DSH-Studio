//
//  RuntimeUpdateCoordinator+DataProfiles.swift
//  DSH Studio
//

import Foundation

/// Data-profile handling for an update: compatibility, switching, and restore.
extension RuntimeUpdateCoordinator {
    /// Whether a Runtime left in this state should be running again afterwards.
    ///
    /// A Runtime that was mid-transition is not restarted, because the interrupted
    /// operation owns that decision.
    ///
    /// - Parameter state: State observed before the update started.
    /// - Returns: `true` when the caller should bring the Runtime back up.
    func shouldResume(after state: RuntimeState) -> Bool {
        switch state {
        case .idle, .terminated:
            return false
        case .provisioning, .updating, .rollingBack:
            return false
        case .launching, .starting, .ready, .failed, .crashed, .stopping:
            return true
        }
    }

    /// Starts the activated Runtime and confirms it becomes ready.
    ///
    /// - Parameters:
    ///   - runtime: Manager to start and verify.
    ///   - keepRunning: Whether to leave the Runtime running once it is ready.
    /// - Returns: `true` when the Runtime reached the ready state.
    func verifyActivatedRuntime(
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

    /// Turns a compatibility verdict into a decision, failing closed.
    ///
    /// Every verdict other than ``RuntimeDataCompatibility/compatible`` blocks the
    /// update, so an unknown or migrated format never silently inherits existing data.
    ///
    /// - Parameter compatibility: Verdict produced from the release's data contract.
    /// - Throws: ``RuntimeUpdateError`` matching the verdict.
    func validateCompatibility(_ compatibility: RuntimeDataCompatibility) throws {
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
    ///
    /// When the current profile cannot be reused, an isolated profile is created
    /// automatically and the old data directory is left untouched.
    func automaticDataProfileIfNeeded(
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

    /// Checks that an update may reuse the selected data profile.
    ///
    /// A profile without a recorded format may only adopt one when its data home is
    /// empty; anything else is treated as unknown compatibility.
    ///
    /// - Parameters:
    ///   - profile: Profile the update would activate.
    ///   - runtimeFormat: Data contract declared by the candidate release.
    ///   - store: Store used to inspect the profile's data home.
    /// - Throws: ``RuntimeUpdateError`` when the profile or the compatibility is invalid.
    func validateDataProfile(
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

    /// Puts the selected profile and data home back after a failed activation.
    ///
    /// The state is first made explicitly stopped, because the child process is already
    /// gone while the coordinator still marks the manager as updating.
    ///
    /// - Parameters:
    ///   - runtime: Manager whose configuration is restored.
    ///   - profile: Profile to restore, or `nil` to fall back to the plain data home.
    ///   - homeURL: Data home recorded before the update.
    func restoreDataProfile(
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

    /// Brings the previous Runtime back after a failed activation.
    ///
    /// - Parameters:
    ///   - runtime: Manager to restart.
    ///   - shouldResume: Whether the Runtime was running before the update.
    func relaunchOldRuntime(_ runtime: RuntimeManager, shouldResume: Bool) async {
        guard shouldResume else {
            runtime.setRuntimeOperationState(.terminated)
            return
        }
        runtime.setRuntimeOperationState(.terminated)
        runtime.start()
        _ = await waitUntilReady(runtime)
    }

    /// Waits for the Runtime to report ready, bounded by its startup timeout.
    ///
    /// - Parameter runtime: Manager to observe.
    /// - Returns: `true` when the Runtime became ready before the deadline.
    func waitUntilReady(_ runtime: RuntimeManager) async -> Bool {
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
