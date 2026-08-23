//
//  RuntimeUpdateCoordinator+DataProfiles.swift
//  DSH Studio
//

import Foundation

extension RuntimeUpdateCoordinator {
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
    /// When the current profile cannot be reused, create an isolated profile
    /// automatically and leave the old data directory untouched.
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

    func relaunchOldRuntime(_ runtime: RuntimeManager, shouldResume: Bool) async {
        guard shouldResume else {
            runtime.setRuntimeOperationState(.terminated)
            return
        }
        runtime.setRuntimeOperationState(.terminated)
        runtime.start()
        _ = await waitUntilReady(runtime)
    }

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
