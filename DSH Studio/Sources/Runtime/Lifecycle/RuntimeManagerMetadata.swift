//
//  RuntimeManagerMetadata.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import DeepSeekLogging
import Foundation

/// RuntimeManager helpers for adopting versioned installations and exposing
/// their metadata to the update coordinator and settings bridge.
extension RuntimeManager {
    public var dataHomeURL: URL {
        configuration.dshHome
    }

    /// Selects a persisted data profile for the next Runtime launch. The
    /// caller must stop the Runtime first so no Harness process can continue
    /// writing to the old data directory during the switch.
    public func selectDataProfile(_ profile: RuntimeDataProfile) throws {
        guard profile.isValid else {
            throw RuntimeDataProfileStoreError.invalidProfile
        }
        guard state == .idle || state == .terminated || state == .failed else {
            throw RuntimeDataProfileStoreError.persistenceFailed("Runtime 尚未停止")
        }
        configuration.dshHome = profile.homeURL
        activeDataProfile = profile
        if let selector = runtimeUpdater as? any RuntimeDataProfileSelecting {
            selector.setDataProfileID(profile.id)
        }
        runtimeVersionStatus = runtimeUpdater?.versionStatus()
    }

    /// Loads the profile that owns the current DSH_HOME without changing any
    /// persisted active state. Activation is deferred until health-check
    /// success so a Runtime that fails to start cannot become authoritative.
    func loadSelectedDataProfile() {
        guard let dataProfileStore else { return }
        activeDataProfile = dataProfileStore.profile(forHomeURL: configuration.dshHome)
        if let selector = runtimeUpdater as? any RuntimeDataProfileSelecting {
            selector.setDataProfileID(activeDataProfile?.id)
        }
        runtimeVersionStatus = runtimeUpdater?.versionStatus()
    }

    /// Prevents a known Runtime from opening a data profile whose format is
    /// unknown or incompatible. A legacy Runtime with no format declaration
    /// remains usable; a declared-format update is checked separately before
    /// it can reuse the existing data home.
    func validateDataProfileForCurrentRuntime() -> Bool {
        guard let provisioner,
              let manifest = RuntimeLocator.installationManifest(root: provisioner.root) else {
            return true
        }
        guard let profile = activeDataProfile else {
            fail(.dataCompatibilityUnknown)
            return false
        }

        guard let runtimeFormat = manifest.dataFormat else {
            guard profile.dataFormatID == nil else {
                fail(.dataCompatibilityUnknown)
                return false
            }
            return true
        }

        guard let profileFormatID = profile.dataFormatID else {
            if dataProfileStore?.isDataHomeEmpty(profile.homeURL) == true {
                return true
            }
            fail(.dataCompatibilityUnknown)
            return false
        }
        switch runtimeFormat.compatibility(with: profileFormatID) {
        case .compatible:
            return true
        case .unknown:
            fail(.dataCompatibilityUnknown)
            return false
        case .incompatible:
            fail(.dataIncompatible)
            return false
        case .requiresMigration:
            fail(.dataMigrationRequired)
            return false
        }
    }

    /// Records a Runtime/profile pair only after the selected Runtime has
    /// passed the normal Harness health check. Existing profiles without an
    /// explicit format remain unknown and are never assigned one by inference.
    @discardableResult
    func activateSelectedDataProfileIfPossible() -> Bool {
        guard let dataProfileStore,
              let manifest = provisioner.flatMap({ RuntimeLocator.installationManifest(root: $0.root) }) else {
            return true
        }

        do {
            let profile: RuntimeDataProfile
            if let activeDataProfile {
                profile = activeDataProfile
            } else {
                profile = try dataProfileStore.ensureLegacyProfile(homeURL: configuration.dshHome)
            }
            activeDataProfile = try dataProfileStore.activate(
                profile: profile,
                runtimeManifest: manifest,
                dataHomeWasEmptyAtLaunch: dataHomeWasEmptyBeforeLaunch
            )
            if let selector = runtimeUpdater as? any RuntimeDataProfileSelecting {
                selector.setDataProfileID(activeDataProfile?.id)
            }
            return true
        } catch {
            logs.log(
                component: "Runtime",
                level: "warn",
                message: "active data profile was not updated: \(LogRedactor.redact(error.localizedDescription))"
            )
            return false
        }
    }

    func refreshRuntimeVersions() {
        nodeVersion = RuntimeLocator.nodeVersion(nodeExecutable: configuration.nodeExecutable)
        harnessVersion = RuntimeLocator.packageJSONVersion(at: configuration.harnessEntry)
    }

    func adoptInstalledRuntimeIfAvailable() {
        guard let provisioner,
              let manifest = RuntimeLocator.installationManifest(root: provisioner.root),
              RuntimeLocator.isCompleteInstallation(
                  root: provisioner.root,
                  architecture: provisioner.architecture
              ) else {
            return
        }
        configuration.nodeExecutable = RuntimeLocator.nodeExecutable(
            root: provisioner.root,
            architecture: provisioner.architecture
        )
        configuration.pnpmExecutable = RuntimeLocator.pnpmExecutable(
            root: provisioner.root,
            architecture: provisioner.architecture,
            harnessVersion: manifest.harnessVersion
        )
        configuration.harnessEntry = RuntimeLocator.harnessEntry(
            root: provisioner.root,
            architecture: provisioner.architecture,
            harnessVersion: manifest.harnessVersion
        )
        configuration.expectedNodeVersion = manifest.nodeVersion
        configuration.expectedHarnessVersion = manifest.harnessVersion
    }

    func applyRuntimeResult(_ result: RuntimeProvisioningResult) {
        configuration.nodeExecutable = RuntimeLocator.nodeExecutable(
            root: result.root,
            architecture: result.architecture
        )
        configuration.pnpmExecutable = RuntimeLocator.pnpmExecutable(
            root: result.root,
            architecture: result.architecture,
            harnessVersion: result.manifest.harnessVersion
        )
        configuration.harnessEntry = RuntimeLocator.harnessEntry(
            root: result.root,
            architecture: result.architecture,
            harnessVersion: result.manifest.harnessVersion
        )
        configuration.expectedNodeVersion = result.manifest.nodeVersion
        configuration.expectedHarnessVersion = result.manifest.harnessVersion
        refreshRuntimeMetadata()
    }

    /// Refreshes the visible Runtime metadata after an install or rollback.
    func refreshRuntimeMetadata() {
        refreshRuntimeVersions()
        runtimeVersionStatus = runtimeUpdater?.versionStatus()
    }

    func setRuntimeVersionStatus(_ status: RuntimeVersionStatus) {
        runtimeVersionStatus = status
    }

    /// Applies a verified catalog release as the next Runtime target. The
    /// currently running process and its data home are left untouched.
    @discardableResult
    public func setRuntimeRelease(_ release: RuntimeReleaseDescriptor) -> Bool {
        guard runtimeUpdateCoordinator?.isBusy != true else {
            logs.log(
                component: "Runtime",
                level: "info",
                message: "deferred verified Runtime release while an update operation is active"
            )
            return false
        }
        guard state != .provisioning,
              state != .updating,
              state != .rollingBack else {
            logs.log(
                component: "Runtime",
                level: "info",
                message: "deferred verified Runtime release while an operation is active"
            )
            return false
        }
        guard let updater = runtimeUpdater as? any RuntimeReleaseUpdating else {
            return false
        }
        do {
            try updater.setRelease(release)
            refreshRuntimeMetadata()
            return true
        } catch {
            logs.log(
                component: "Runtime",
                level: "warn",
                message: "verified Runtime release was rejected: \(LogRedactor.redact(error.localizedDescription))"
            )
            return false
        }
    }

    /// Allows the update coordinator to expose a short-lived operation state.
    func setRuntimeOperationState(_ state: RuntimeState) {
        self.state = state
    }

    public func retry() {
        guard state == .failed || state == .crashed else { return }
        restartTracker.reset()
        restartCount = 0
        start()
    }

    /// Updates launch-only configuration after the child process has stopped.
    public func updateWorkspace(_ workspace: URL) {
        guard state == .idle || state == .terminated || state == .failed || state == .crashed else { return }
        configuration.workspace = workspace.standardizedFileURL
    }

    /// Selects the Harness composition used by the next launch.
    public func updateProfileName(_ profileName: String) {
        guard state == .idle || state == .terminated || state == .failed || state == .crashed else { return }
        configuration.profileName = profileName
    }

    public func updateStartupTimeout(_ timeout: TimeInterval) {
        configuration.startupTimeout = timeout
    }
}
