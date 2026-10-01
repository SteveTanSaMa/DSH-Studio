//
//  AppModel+RuntimeFactory.swift
//  DSH Studio
//

import DeepSeekRuntime
import Foundation

/// Factory for the production manager wired to the app's support locations.
extension RuntimeManager {
    /// Creates the production manager with the current app support locations.
    ///
    /// Development overrides intentionally skip provisioning; release builds
    /// use the verified online provisioner when the Runtime is absent.
    static func makeMVP(
        workspace: URL,
        dshHome: URL? = nil,
        profileName: String = "web",
        environment: [String: String] = [:],
        release requestedRelease: RuntimeReleaseDescriptor? = nil,
        catalogService: RuntimeCatalogService? = nil
    ) -> RuntimeManager {
        let support = RuntimeLocator.applicationSupportDirectory()!
        let dataProfileStore = RuntimeDataProfileStore(supportDirectory: support)
        let migratedRoot: URL?
        if !RuntimeLocator.usesDevelopmentOverride() {
            // This also repairs a legacy root left behind by an interrupted
            // activation when its manifest still matches active-state.json.
            migratedRoot = RuntimeLocator.migrateLegacyRuntimeIfNeeded(
                supportDirectory: support
            )
        } else {
            migratedRoot = nil
        }
        let catalogRelease = requestedRelease
            ?? catalogService?.bundledResolution()?.release
            ?? RuntimeReleaseCatalog.load(architecture: RuntimeLocator.architectureDirectory())
        let root = migratedRoot
            ?? RuntimeLocator.runtimeRoot(runtimeVersion: catalogRelease?.runtimeVersion)
        // An installed Runtime remains launchable offline even when this App
        // has no bundled catalog and cannot reach the signed remote catalog.
        // Its manifest is enough to describe the current executable tree; it
        // is deliberately not treated as an update source.
        let release = catalogRelease
            ?? RuntimeLocator.installationManifest(root: root).map(RuntimeReleaseDescriptor.init(manifest:))
        let installedHarnessVersion = RuntimeLocator.installationManifest(root: root)?.harnessVersion
            ?? release?.harnessVersion
            ?? RuntimeLocator.harnessVersion
        let dshHome = dshHome ?? RuntimeLocator.defaultDSHHome() ?? support
            .appendingPathComponent("DSH_HOME", isDirectory: true)
        _ = try? dataProfileStore.ensureLegacyProfile(homeURL: dshHome)
        let harnessProfiles = HarnessProfileStore(dshHome: dshHome, supportDirectory: support)
        // Every launch refreshes the first-party settings page in the profile it is
        // about to boot, so a profile created later cannot silently lose DSH Studio's
        // settings section. A machine with no Runtime yet has nothing to install the
        // page against; `RuntimeManager.prelaunchPreparation` writes it once
        // provisioning finished and before Harness starts.
        let runtimeNodeModules = RuntimeLocator.harnessNodeModules(
            harnessEntry: RuntimeLocator.harnessEntry(
                root: root,
                harnessVersion: installedHarnessVersion
            )
        )
        if let source = Bundle.main.resourceURL?.appendingPathComponent(
            HarnessProfileStore.studioSettingsResourceName,
            isDirectory: true
        ),
        FileManager.default.fileExists(atPath: source.path),
        FileManager.default.fileExists(atPath: runtimeNodeModules.path) {
            do {
                try harnessProfiles.installStudioSettingsPlugin(
                    from: source,
                    runtimeNodeModules: runtimeNodeModules,
                    profileName: profileName
                )
            } catch {
                NSLog("DSH Studio settings plugin installation failed: %@", error.localizedDescription)
            }
        }
        let logDirectory = support.appendingPathComponent("Logs", isDirectory: true)
        let logURL = logDirectory
            .appendingPathComponent("runtime.log")
        let configuration = RuntimeConfiguration(
            nodeExecutable: RuntimeLocator.nodeExecutable(root: root),
            harnessEntry: RuntimeLocator.harnessEntry(
                root: root,
                harnessVersion: installedHarnessVersion
            ),
            dshHome: dshHome,
            workspace: workspace,
            pnpmExecutable: RuntimeLocator.pnpmExecutable(
                root: root,
                harnessVersion: installedHarnessVersion
            ),
            environment: environment,
            expectedHarnessVersion: installedHarnessVersion,
            profileName: profileName,
        )
        let provisioner: (any RuntimeProvisioning)? =
            RuntimeLocator.usesDevelopmentOverride() || RuntimeLocator.isBundledRuntimeRoot(root)
            ? nil
            : RuntimeProvisioner(
                root: root,
                release: release,
                dataProfileStore: dataProfileStore,
                // Verified archives and unfinished downloads live here rather than in the
                // staging directory, so a retry after a failed install does not start the
                // 188 MiB download over.
                downloadCacheDirectory: support.appendingPathComponent("RuntimeDownloads", isDirectory: true)
            )
        return RuntimeManager(
            configuration: configuration,
            logFileURL: logURL,
            provisioner: provisioner,
            dataProfileStore: dataProfileStore,
            crashReportDirectory: logDirectory.appendingPathComponent("CrashReports", isDirectory: true)
        )
    }
}
