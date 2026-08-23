//
//  AppModel.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import AppKit
import Combine
import DeepSeekRuntime
import Foundation

/// Coordinates user settings with the RuntimeManager used by the main window.
@MainActor
final class AppModel: ObservableObject {
    @Published var runtime: RuntimeManager

    var settings = SettingsStore()
    private(set) var currentDataHomeURL: URL
    private let runtimeCatalogService: RuntimeCatalogService
    private var runtimeRelease: RuntimeReleaseDescriptor?
    private(set) var latestSignedRuntimeRelease: RuntimeReleaseDescriptor?
    private var runtimeCancellable: AnyCancellable?

    init() {
        let support = RuntimeLocator.applicationSupportDirectory()
        runtimeCatalogService = RuntimeCatalogService(supportDirectory: support)
        currentDataHomeURL = settings.dshHomeURL
        if let support,
           let activeHome = RuntimeDataProfileStore(supportDirectory: support)
               .activeProfile()?.homeURL {
            // The last health-checked Runtime/profile pair is the durable
            // source of truth after an interrupted settings/update transition.
            currentDataHomeURL = activeHome
        }
        runtimeRelease = runtimeCatalogService.bundledResolution()?.release
        runtime = RuntimeManager.makeMVP(
            workspace: settings.workspaceURL,
            dshHome: currentDataHomeURL,
            release: runtimeRelease,
            catalogService: runtimeCatalogService
        )
        bindRuntime()
        applySettings()
    }

    private func bindRuntime() {
        // RuntimeManager publishes its own state. Forwarding that publisher
        // keeps the SwiftUI view tree in sync when the manager is replaced.
        runtimeCancellable = runtime.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Starts the local Runtime and lets its state drive the initial UI.
    func start() {
        Task { @MainActor [weak self] in
            guard let self else { return }

            // A distribution may intentionally omit a bundled catalog and
            // rely on the signed remote catalog for first-launch discovery.
            // Resolve it before provisioning a missing/invalid Runtime so the
            // production path never falls back to an artifact-less descriptor.
            let needsCatalogBeforeStart = self.runtimeRelease == nil
                && (self.runtime.runtimeVersionStatus?.kind == .missing
                    || self.runtime.runtimeVersionStatus?.kind == .invalid)
            if needsCatalogBeforeStart {
                await self.refreshRuntimeCatalog()
            }

            self.runtime.start()
            await self.waitForRuntimeOperationToFinish()
            if !needsCatalogBeforeStart || self.runtimeRelease == nil {
                await self.refreshRuntimeCatalog()
            }
        }
    }

    private func waitForRuntimeOperationToFinish() async {
        while runtime.state == .provisioning
            || runtime.state == .updating
            || runtime.state == .rollingBack {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Performs online catalog discovery without interrupting the current
    /// Harness process. Only a verified signed release changes the next update
    /// target or the latest-version text shown in settings.
    func refreshRuntimeCatalog(prepareCandidate: Bool = true) async {
        do {
            let resolution = try await runtimeCatalogService.signedResolution()
            latestSignedRuntimeRelease = resolution.release
            objectWillChange.send()
            if runtime.setRuntimeRelease(resolution.release) {
                runtimeRelease = resolution.release
                if prepareCandidate {
                    await prepareRuntimeUpdate()
                }
            }
        } catch {
            runtime.logs.log(
                component: "Runtime",
                level: "info",
                message: "Runtime catalog discovery unavailable: \(error.localizedDescription)"
            )
        }
    }

    /// The settings bridge uses this path for an explicit check so the remote
    /// catalog is consulted before comparing installed and available versions.
    @discardableResult
    func checkRuntimeVersion() async -> RuntimeVersionStatus? {
        await waitForRuntimeOperationToFinish()
        // Checking must not download, unpack, or verify a Runtime archive on
        // the WebView request path. Preparation remains an explicit update
        // operation or the normal background startup flow.
        await refreshRuntimeCatalog(prepareCandidate: false)
        return runtime.runtimeUpdateCoordinator?.checkVersion()
    }

    private func prepareRuntimeUpdate() async {
        guard let coordinator = runtime.runtimeUpdateCoordinator else { return }
        do {
            try await coordinator.prepare()
        } catch RuntimeUpdateError.noUpdateAvailable {
            return
        } catch {
            runtime.logs.log(
                component: "Runtime",
                level: "info",
                message: "Runtime candidate preparation unavailable: \(error.localizedDescription)"
            )
        }
    }

    func applySettings() {
        // Runtime recovery is an app reliability mechanism, not a user-facing toggle.
        runtime.restartPolicy.enabled = true
    }

    /// Performs the two-phase Runtime update against a selected data profile.
    /// Settings are updated only when the profile has actually become active;
    /// the first call may merely prepare the Runtime candidate.
    func updateRuntime() async throws {
        guard let coordinator = runtime.runtimeUpdateCoordinator else {
            throw RuntimeUpdateError.unavailable
        }
        try await coordinator.update()
        syncCurrentDataHomeURL()
    }

    /// Retained for internal callers that need to activate a specific profile.
    func updateRuntime(using profile: RuntimeDataProfile) async throws {
        guard let coordinator = runtime.runtimeUpdateCoordinator else {
            throw RuntimeUpdateError.unavailable
        }
        try await coordinator.update(using: profile)
        syncCurrentDataHomeURL()
    }

    var latestSignedHarnessVersion: String? {
        latestSignedRuntimeRelease?.harnessVersion
    }

    var hasVerifiedRuntimeUpdate: Bool {
        latestSignedRuntimeRelease != nil
            && runtime.runtimeVersionStatus?.updateAvailable == true
    }

    private func syncCurrentDataHomeURL() {
        let updated = runtime.configuration.dshHome.standardizedFileURL
        guard updated != currentDataHomeURL.standardizedFileURL else { return }
        currentDataHomeURL = updated
        objectWillChange.send()
    }

    @discardableResult
    /// Opens the directory containing the sanitized runtime log files.
    func openLogs() -> Bool {
        let support = RuntimeLocator.applicationSupportDirectory()
        guard let logs = support?.appendingPathComponent("Logs", isDirectory: true) else { return false }
        do {
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        } catch {
            return false
        }
        return NSWorkspace.shared.open(logs)
    }

    @discardableResult
    func openDataFolder() -> Bool {
        let dataFolder = currentDataHomeURL
        do {
            try FileManager.default.createDirectory(
                at: dataFolder,
                withIntermediateDirectories: true
            )
        } catch {
            return false
        }
        return NSWorkspace.shared.open(dataFolder)
    }

    @discardableResult
    func copyDiagnostics() -> Bool {
        let status = runtime.runtimeVersionStatus
        let installed = status?.installed
        let available = status?.available
        let dataFormat = runtime.activeDataProfile?.dataFormatID
            ?? installed?.dataFormat?.id
            ?? "未知"
        let lines = [
            "DSH Studio",
            "工作区：" + settings.workspaceURL.path,
            "数据文件夹：" + currentDataHomeURL.path,
            "Harness：" + (runtime.harnessVersion ?? "未知"),
            "Harness 状态：" + (status?.harnessDisplayName ?? "正在检查"),
            "Runtime 状态：" + runtime.state.displayName,
            "Runtime 构建：" + (installed?.runtimeVersion ?? "未知"),
            "可用 Harness：" + (available?.harnessVersion ?? "未知"),
            "可用 Runtime 构建：" + (available?.runtimeVersion ?? "未知"),
            "架构：" + (installed?.architecture ?? available?.architecture ?? "未知"),
            "Node：" + (installed?.nodeVersion ?? runtime.nodeVersion ?? "未知"),
            "pnpm：" + (installed?.pnpmVersion ?? available?.pnpmVersion ?? "未知"),
            "数据格式：" + dataFormat,
            "Node 校验：" + (available?.nodeArchiveSHA256 ?? "未知"),
            "Runtime 校验：" + (available?.artifact?.sha256 ?? "未知"),
            "错误：" + (runtime.lastError?.uiDescription ?? "无")
        ].joined(separator: "\n")

        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(lines, forType: .string)
    }

}

extension RuntimeManager {
    /// Creates the production manager with the current app support locations.
    ///
    /// Development overrides intentionally skip provisioning; release builds
    /// use the verified online provisioner when the Runtime is absent.
    static func makeMVP(
        workspace: URL,
        dshHome: URL? = nil,
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
            pnpmExecutable: RuntimeLocator.pnpmExecutable(root: root)
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
