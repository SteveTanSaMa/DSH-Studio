//
//  AppModel+RuntimeFactory.swift
//  DSH Studio
//

import DeepSeekRuntime
import Foundation

extension RuntimeManager {
    /// Creates the production manager with the current app support locations.
    ///
    /// Development overrides intentionally skip provisioning; release builds
    /// use the verified online provisioner when the Runtime is absent.
    static func makeMVP(
        workspace: URL,
        dshHome: URL? = nil,
        profileName: String = "web",
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
        let dshHome = dshHome ?? RuntimeLocator.defaultDSHHome() ?? support
            .appendingPathComponent("DSH_HOME", isDirectory: true)
        _ = try? dataProfileStore.ensureLegacyProfile(homeURL: dshHome)
        let logURL = support
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("runtime.log")
        let configuration = RuntimeConfiguration(
            nodeExecutable: RuntimeLocator.nodeExecutable(root: root),
            harnessEntry: RuntimeLocator.harnessEntry(root: root),
            dshHome: dshHome,
            workspace: workspace,
            pnpmExecutable: RuntimeLocator.pnpmExecutable(root: root),
            profileName: profileName
        )
        let provisioner: (any RuntimeProvisioning)? =
            RuntimeLocator.usesDevelopmentOverride() || RuntimeLocator.isBundledRuntimeRoot(root)
            ? nil
            : RuntimeProvisioner(
                root: root,
                release: release,
                dataProfileStore: dataProfileStore
            )
        return RuntimeManager(
            configuration: configuration,
            logFileURL: logURL,
            provisioner: provisioner,
            dataProfileStore: dataProfileStore
        )
    }
}
