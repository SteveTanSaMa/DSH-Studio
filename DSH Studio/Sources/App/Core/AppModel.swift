//
//  AppModel.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import AppKit
import Combine
import DeepSeekLogging
import DeepSeekRuntime
import Foundation
import UniformTypeIdentifiers

/// Coordinates user settings with the RuntimeManager used by the main window.
@MainActor
final class AppModel: ObservableObject {
    @Published var runtime: RuntimeManager

    var settings = SettingsStore()
    let harnessProfiles: HarnessProfileStore
    let pluginMarket: PluginMarketManager
    private(set) var presetTransfer: AgentPresetTransferManager
    private(set) var currentDataHomeURL: URL
    private(set) var selectedHarnessProfileName: String
    private let runtimeCatalogService: RuntimeCatalogService
    private let notificationCoordinator: AppNotificationCoordinator
    private var runtimeRelease: RuntimeReleaseDescriptor?
    private(set) var latestSignedRuntimeRelease: RuntimeReleaseDescriptor?
    private var runtimeCancellable: AnyCancellable?
    private var runtimeURLCancellable: AnyCancellable?
    private var runtimeStateCancellable: AnyCancellable?
    private var pluginMarketCancellable: AnyCancellable?
    private var pluginMarketRefreshTask: Task<Void, Never>?
    private var pluginMarketAutoInstallAttempted = false

    init() {
        let support = RuntimeLocator.applicationSupportDirectory()
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DSH Studio", isDirectory: true)
        runtimeCatalogService = RuntimeCatalogService(supportDirectory: support)
        currentDataHomeURL = settings.dshHomeURL
        notificationCoordinator = AppNotificationCoordinator(settings: settings)
        if let activeHome = RuntimeDataProfileStore(supportDirectory: support)
            .activeProfile()?.homeURL {
            // The last health-checked Runtime/profile pair is the durable
            // source of truth after an interrupted settings/update transition.
            currentDataHomeURL = activeHome
        }
        harnessProfiles = HarnessProfileStore(
            dshHome: currentDataHomeURL,
            supportDirectory: support
        )
        presetTransfer = AgentPresetTransferManager(dshHome: currentDataHomeURL)
        let profileSelection = harnessProfiles.startupProfile()
        selectedHarnessProfileName = profileSelection.active
        runtimeRelease = runtimeCatalogService.bundledResolution()?.release
        let configuredRuntime = RuntimeManager.makeMVP(
            workspace: settings.workspaceURL,
            dshHome: currentDataHomeURL,
            profileName: selectedHarnessProfileName,
            release: runtimeRelease,
            catalogService: runtimeCatalogService
        )
        runtime = configuredRuntime
        pluginMarket = PluginMarketManager(
            runtime: configuredRuntime,
            supportDirectory: support
        )
        bindRuntime()
        applySettings()
    }

    private func bindRuntime() {
        // RuntimeManager publishes its own state. Forwarding that publisher
        // keeps the SwiftUI view tree in sync when the manager is replaced.
        runtimeCancellable = runtime.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        runtimeURLCancellable = runtime.$readyURL
            .removeDuplicates()
            .sink { [weak self] url in
                self?.notificationCoordinator.updateRuntimeURL(url)
                self?.schedulePluginMarketRefresh()
            }
        runtimeStateCancellable = runtime.$state
            .removeDuplicates()
            .sink { [weak self] state in
                if state == .ready, let self {
                    try? self.harnessProfiles.markHealthy(name: self.runtime.configuration.profileName)
                    self.selectedHarnessProfileName = self.runtime.configuration.profileName
                }
                self?.schedulePluginMarketRefresh()
            }
        pluginMarketCancellable = pluginMarket.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    deinit {
        pluginMarketRefreshTask?.cancel()
    }

    func stopNotifications() {
        notificationCoordinator.stop()
    }

    /// Starts the local Runtime and lets its state drive the initial UI.
    func start() {
        Task { @MainActor [weak self] in
            guard let self else { return }

            self.pluginMarketAutoInstallAttempted = false

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
            if self.runtime.configuration.profileName == HarnessProfileStore.defaultProfileName {
                await self.pluginMarket.refresh()
                await self.installPluginMarketIfNeeded()
            }
            if !needsCatalogBeforeStart || self.runtimeRelease == nil {
                await self.refreshRuntimeCatalog()
            }
        }
    }

    private func waitForRuntimeOperationToFinish() async {
        while true {
            switch runtime.state {
            case .provisioning, .updating, .rollingBack, .launching, .starting, .stopping:
                try? await Task.sleep(nanoseconds: 100_000_000)
            case .idle, .ready, .failed, .terminated, .crashed:
                return
            }
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

    private func installPluginMarketIfNeeded() async {
        guard runtime.state == .ready,
              runtime.configuration.profileName == HarnessProfileStore.defaultProfileName,
              !pluginMarketAutoInstallAttempted else { return }
        pluginMarketAutoInstallAttempted = true
        do {
            _ = try await pluginMarket.ensureInstalled()
        } catch {
            runtime.logs.log(
                component: "PluginMarket",
                level: "error",
                message: "automatic Plugin Market installation failed: \(error.localizedDescription)"
            )
        }
    }

    private func schedulePluginMarketRefresh() {
        pluginMarketRefreshTask?.cancel()
        pluginMarketRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.pluginMarket.refresh()
            await self.installPluginMarketIfNeeded()
        }
    }

    /// Performs the two-phase Runtime update against a selected data profile.
    /// Settings are updated only when the profile has actually become active;
    /// the first call may merely prepare the Runtime candidate.
    func updateRuntime() async throws {
        guard let coordinator = runtime.runtimeUpdateCoordinator else {
            throw RuntimeUpdateError.unavailable
        }
        pluginMarketAutoInstallAttempted = false
        try await coordinator.update()
        syncCurrentDataHomeURL()
        schedulePluginMarketRefresh()
    }

    /// Retained for internal callers that need to activate a specific profile.
    func updateRuntime(using profile: RuntimeDataProfile) async throws {
        guard let coordinator = runtime.runtimeUpdateCoordinator else {
            throw RuntimeUpdateError.unavailable
        }
        pluginMarketAutoInstallAttempted = false
        try await coordinator.update(using: profile)
        syncCurrentDataHomeURL()
        schedulePluginMarketRefresh()
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
        presetTransfer = AgentPresetTransferManager(dshHome: updated)
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

    func chooseWorkspace() async throws -> Bool {
        let panel = NSOpenPanel()
        panel.title = "选择工作区目录"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return false }
        let admitted = try WorkspaceAdmission.validateSelectedDirectory(selectedURL)
        guard admitted != settings.workspaceURL.standardizedFileURL else { return true }

        let oldURL = settings.workspaceURL
        let shouldResume = runtime.state != .idle && runtime.state != .terminated
        await runtime.stop()
        settings.workspaceURL = admitted
        runtime.updateWorkspace(admitted)
        guard shouldResume else { return true }

        runtime.start()
        await waitForRuntimeOperationToFinish()
        guard runtime.state != .failed && runtime.state != .crashed else {
            settings.workspaceURL = oldURL
            runtime.updateWorkspace(oldURL)
            await runtime.stop()
            runtime.start()
            await waitForRuntimeOperationToFinish()
            throw RuntimeError.workspaceFailure(runtime.lastError?.localizedDescription ?? "工作区切换后 Runtime 无法启动")
        }
        return true
    }

    func createHarnessProfile(name: String) throws {
        _ = try harnessProfiles.create(name: name)
        objectWillChange.send()
    }

    func selectHarnessProfile(name: String) async throws -> Bool {
        guard name != runtime.configuration.profileName else { return true }
        try harnessProfiles.select(name: name)
        let oldName = runtime.configuration.profileName
        let shouldResume = runtime.state != .idle && runtime.state != .terminated
        await runtime.stop()
        runtime.updateProfileName(name)
        selectedHarnessProfileName = name
        guard shouldResume else { return true }

        runtime.start()
        await waitForRuntimeOperationToFinish()
        guard runtime.state != .failed && runtime.state != .crashed else {
            let fallback = (try? harnessProfiles.rollbackToLastKnownGood()) ?? oldName
            runtime.updateProfileName(fallback)
            selectedHarnessProfileName = fallback
            await runtime.stop()
            runtime.start()
            await waitForRuntimeOperationToFinish()
            throw RuntimeError.processLaunchFailed(runtime.lastError?.localizedDescription ?? "Profile 启动失败，已恢复上一个可用 Profile")
        }
        try? harnessProfiles.markHealthy(name: name)
        return true
    }

    func deleteHarnessProfile(name: String) throws {
        try harnessProfiles.delete(name: name)
        objectWillChange.send()
    }

    func exportAgentPreset() async throws -> URL? {
        let openPanel = NSOpenPanel()
        openPanel.title = "选择要导出的 Agent Preset"
        openPanel.prompt = "选择"
        openPanel.message = "只能导出用户创建的 Agent Preset"
        openPanel.directoryURL = presetTransfer.userPresetRoot
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        guard openPanel.runModal() == .OK, let source = openPanel.url else {
            return nil
        }
        let presetID = source.lastPathComponent
        let savePanel = NSSavePanel()
        savePanel.title = "保存 Agent Preset"
        savePanel.prompt = "导出"
        savePanel.nameFieldStringValue = "\(presetID).dshpreset"
        savePanel.allowedContentTypes = [UTType(filenameExtension: "dshpreset") ?? .data]
        savePanel.canCreateDirectories = true
        guard savePanel.runModal() == .OK, let destination = savePanel.url else {
            return nil
        }
        try presetTransfer.exportArchive(
            presetID: presetID,
            to: destination,
            sourceHarnessVersion: runtime.harnessVersion
        )
        return destination
    }

    func importAgentPreset() async throws -> String? {
        let openPanel = NSOpenPanel()
        openPanel.title = "选择 Agent Preset 压缩包"
        openPanel.prompt = "打开"
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.allowedContentTypes = [
            UTType(filenameExtension: "dshpreset") ?? .data,
            .zip
        ]
        guard openPanel.runModal() == .OK, let archive = openPanel.url else {
            return nil
        }

        let preview = try presetTransfer.previewImport(from: archive)
        let targetField = NSTextField(string: preview.targetID)
        targetField.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        let details = [
            "Preset：\(preview.manifest.name)",
            "文件：\(preview.fileCount)，大小：\(ByteCountFormatter.string(fromByteCount: preview.uncompressedBytes, countStyle: .file))",
            preview.conflict ? "同名 Preset 已存在，请修改名称。" : "导入后不会覆盖现有 Preset。",
            preview.warnings.joined(separator: "\n")
        ].joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "确认导入 Agent Preset"
        alert.informativeText = details
        alert.accessoryView = targetField
        alert.addButton(withTitle: "导入")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        let installed = try presetTransfer.installImport(
            from: archive,
            requestedID: targetField.stringValue
        )
        return installed.targetID
    }

    func rollbackRuntime() async throws {
        guard let coordinator = runtime.runtimeUpdateCoordinator else {
            throw RuntimeUpdateError.unavailable
        }
        try await coordinator.rollback()
        syncCurrentDataHomeURL()
    }

    func exportDiagnostics() async throws -> URL {
        let support = RuntimeLocator.applicationSupportDirectory()!
        let lines = await diagnosticLines()
        return try await DiagnosticsExporter.export(
            systemInfo: lines.joined(separator: "\n"),
            logsDirectory: support.appendingPathComponent("Logs", isDirectory: true),
            supportDirectory: support
        )
    }

    @discardableResult
    func diagnosticLines() async -> [String] {
        let status = runtime.runtimeVersionStatus
        let installed = status?.installed
        let available = status?.available
        let dataFormat = runtime.activeDataProfile?.dataFormatID
            ?? installed?.dataFormat?.id
            ?? "未知"
        var lines = [
            "DSH Studio",
            "工作区：" + LogRedactor.redactPath(settings.workspaceURL.path),
            "数据文件夹：" + LogRedactor.redactPath(currentDataHomeURL.path),
            "Harness Profile：" + runtime.configuration.profileName,
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
        ]
        lines.append("")
        lines.append(LogRedactor.redact(await pluginMarket.diagnostics()))
        return lines
    }

    @discardableResult
    func copyDiagnostics() async -> Bool {
        let diagnosticText = (await diagnosticLines()).joined(separator: "\n")

        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(diagnosticText, forType: .string)
    }

}
