//
//  RuntimeManagerMetadata.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import DeepSeekLogging
import Foundation

/// RuntimeManager helpers for adopting versioned installations.
///
/// The metadata these helpers expose feeds the update coordinator, the settings
/// bridge, and diagnostics.
extension RuntimeManager {
    /// The data directory the Runtime currently uses.
    public var dataHomeURL: URL {
        configuration.dshHome
    }

    /// Selects a persisted data profile for the next Runtime launch.
    ///
    /// The caller must stop the Runtime first so no Harness process can keep
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

    /// Loads the profile that owns the current `DSH_HOME`.
    ///
    /// No persisted active state is changed: activation is deferred until the
    /// health check succeeds, so a Runtime that fails to start cannot become
    /// authoritative.
    func loadSelectedDataProfile() {
        guard let dataProfileStore else { return }
        activeDataProfile = dataProfileStore.profile(forHomeURL: configuration.dshHome)
        if let selector = runtimeUpdater as? any RuntimeDataProfileSelecting {
            selector.setDataProfileID(activeDataProfile?.id)
        }
        runtimeVersionStatus = runtimeUpdater?.versionStatus()
    }

    /// Whether the current Runtime may open the selected data profile.
    ///
    /// A legacy Runtime with no format declaration remains usable; a declared
    /// format must be compatible, and an update is checked separately before it
    /// may reuse the existing data home.
    func validateDataProfileForCurrentRuntime() -> Bool {
        guard let provisioner,
              let manifest = RuntimeLocator.installationManifest(root: provisioner.root) else {
            return true
        }
        // A launch that did not provision anything never registered the home it is about
        // to use, so the profile is resolved — and, for the app-owned home, registered —
        // here. Without this, a second launch on an already-installed Runtime failed
        // before it could start, while the first launch on the same machine worked.
        if activeDataProfile == nil {
            loadSelectedDataProfile()
        }
        if activeDataProfile == nil, let dataProfileStore,
           let registered = try? dataProfileStore.ensureLegacyProfile(homeURL: configuration.dshHome) {
            activeDataProfile = registered
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
            // The profile has no recorded format yet. Recording the one this Runtime
            // declares before the launch is what keeps a failed start from stranding the
            // machine: Harness writes into the home as soon as it runs, and a non-empty
            // home with no recorded format is refused by every later launch. The Runtime
            // is the one this app ships, so its declaration describes what it wrote there.
            if assignDataFormat(runtimeFormat.id, to: profile) {
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

    /// Records the data format a Runtime declared for one profile.
    ///
    /// - Parameters:
    ///   - formatID: Format identifier taken from the Runtime manifest.
    ///   - profile: Profile that is about to open that Runtime's data home.
    /// - Returns: Whether the profile now carries the format.
    private func assignDataFormat(_ formatID: String, to profile: RuntimeDataProfile) -> Bool {
        guard let dataProfileStore else { return false }
        let updated = profile.replacing(dataFormatID: formatID)
        do {
            try dataProfileStore.save(updated)
            activeDataProfile = updated
            return true
        } catch {
            logs.log(
                component: "Runtime",
                level: "warn",
                message: "data format was not recorded: \(LogRedactor.redact(error.localizedDescription))"
            )
            return false
        }
    }

    /// Records the Runtime and profile pair after a successful health check.
    ///
    /// Existing profiles without an explicit format stay unknown and are never
    /// assigned one by inference.
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

    /// Re-reads the Node.js and Harness versions from the configured paths.
    func refreshRuntimeVersions() {
        nodeVersion = RuntimeLocator.nodeVersion(nodeExecutable: configuration.nodeExecutable)
        harnessVersion = RuntimeLocator.packageJSONVersion(at: configuration.harnessEntry)
    }

    /// Adopts the versions of a complete installation already on disk.
    ///
    /// Called during initialization so a valid installation is used as-is instead of
    /// being reinstalled; incomplete or missing installations leave the configuration
    /// untouched.
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

    /// Points the configuration at a freshly installed Runtime.
    ///
    /// - Parameter result: Installation that was just provisioned or activated.
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

    /// Publishes a version comparison produced by the update coordinator.
    ///
    /// - Parameter status: Comparison to publish.
    func setRuntimeVersionStatus(_ status: RuntimeVersionStatus) {
        runtimeVersionStatus = status
    }

    /// Applies a verified catalog release as the next Runtime target.
    ///
    /// The running process and its data home are left untouched.
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

    /// Restarts the Runtime after a failure, clearing the crash budget first.
    ///
    /// Ignored unless the current state is failed or crashed.
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

    /// Changes how long a launch may take before it is failed.
    ///
    /// - Parameter timeout: Seconds to wait for the ready line.
    public func updateStartupTimeout(_ timeout: TimeInterval) {
        configuration.startupTimeout = timeout
    }
}
