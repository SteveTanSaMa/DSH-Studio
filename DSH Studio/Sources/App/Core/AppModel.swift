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
    /// The Runtime whose process, versions, and profiles this model owns.
    @Published var runtime: RuntimeManager

    /// App-owned preferences shared with the Harness settings page.
    var settings = SettingsStore()
    private(set) var harnessProfiles: HarnessProfileStore
    /// Native lifecycle manager for the fixed dsh-market plugin.
    let pluginMarket: PluginMarketManager
    private(set) var presetTransfer: AgentPresetTransferManager
    private(set) var currentDataHomeURL: URL
    private(set) var selectedHarnessProfileName: String
    private let runtimeCatalogService: RuntimeCatalogService
    private let supportDirectory: URL
    private let notificationCoordinator: AppNotificationCoordinator
    private var runtimeRelease: RuntimeReleaseDescriptor?
    private(set) var latestSignedRuntimeRelease: RuntimeReleaseDescriptor?
    private var runtimeCancellable: AnyCancellable?
    private var runtimeURLCancellable: AnyCancellable?
    private var runtimeStateCancellable: AnyCancellable?
    private var pluginMarketCancellable: AnyCancellable?
    private var pluginMarketRefreshTask: Task<Void, Never>?
    private var pluginMarketAutoInstallAttempted = false
    private var pluginMarketRestartInProgress = false
    private let terminalFileGenerator = RuntimeTerminalFileGenerator()

    /// Wires the stores, resolves the Runtime root, and binds runtime updates.
    ///
    /// The data home is taken from the last health-checked data profile when one is
    /// recorded, so an interrupted update cannot silently point the app at the wrong
    /// `DSH_HOME`.
    init() {
        let support = RuntimeLocator.applicationSupportDirectory()
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DSH Studio", isDirectory: true)
        supportDirectory = support
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

    /// Cancels the pending plugin-market refresh when the model goes away.
    deinit {
        pluginMarketRefreshTask?.cancel()
    }

    /// Handles dsh-market's restart request inside the app-owned lifecycle.
    ///
    /// This prevents the market from forking an unmanaged Harness replacement and
    /// keeps its intentional SIGTERM from being reported as a crash.
    func restartRuntimeForPluginMarket() {
        guard !pluginMarketRestartInProgress else { return }
        guard runtime.state == .ready else {
            runtime.logs.log(
                component: "PluginMarket",
                level: "warn",
                message: "ignored restart request while Runtime state is \(runtime.state)"
            )
            return
        }
        pluginMarketRestartInProgress = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pluginMarketRestartInProgress = false }
            guard await self.runtime.restart() else {
                self.runtime.logs.log(
                    component: "PluginMarket",
                    level: "error",
                    message: "native Plugin Market Runtime restart did not start"
                )
                return
            }
            await self.waitForRuntimeOperationToFinish()
        }
    }

    /// Stops the notification stream; called while the app is terminating.
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

            let canInstallPluginMarketBeforeStart = self.runtime.configuration.profileName
                == HarnessProfileStore.defaultProfileName
                && !needsCatalogBeforeStart
                && self.runtime.harnessVersion != nil
                && self.runtime.configuration.pnpmExecutable != nil
            if canInstallPluginMarketBeforeStart {
                // Profile mutation is safe while Runtime is idle. Doing it
                // here avoids the stop/restart cycle used for live changes.
                await self.pluginMarket.refresh()
                await self.installPluginMarketIfNeeded(allowIdle: true)
            }

            self.runtime.start()
            await self.waitForRuntimeOperationToFinish()
            if self.runtime.configuration.profileName == HarnessProfileStore.defaultProfileName {
                await self.pluginMarket.refresh()
                if !self.pluginMarketAutoInstallAttempted {
                    await self.installPluginMarketIfNeeded()
                }
            }
            if !needsCatalogBeforeStart || self.runtimeRelease == nil {
                await self.refreshRuntimeCatalog()
            }
        }
    }

    /// Waits until the Runtime leaves every transition state.
    ///
    /// Polls rather than observing, so a caller can sequence work after a
    /// stop/start pair without holding a subscription.
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

    /// Performs online catalog discovery without interrupting Harness.
    ///
    /// Only a verified signed release changes the next update target or the
    /// latest-version text shown in Settings.
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

    /// Checks for a Runtime update after consulting the remote catalog.
    ///
    /// Used by the explicit check in the app menu and the settings window.
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

    /// Applies settings that are enforced rather than user-configurable.
    ///
    /// Runtime recovery is an app reliability mechanism, so it is always enabled.
    func applySettings() {
        // Runtime recovery is an app reliability mechanism, not a user-facing toggle.
        runtime.restartPolicy.enabled = true
    }

    private func installPluginMarketIfNeeded(allowIdle: Bool = false) async {
        let canInstallWhileIdle = allowIdle && runtime.state == .idle
        guard (runtime.state == .ready || canInstallWhileIdle),
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
    ///
    /// Settings are updated only when the profile actually became active; the first
    /// call may merely prepare the candidate.
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

    /// Harness version of the newest verified catalog release, when one was found.
    var latestSignedHarnessVersion: String? {
        latestSignedRuntimeRelease?.harnessVersion
    }

    /// Whether a verified release is both known and newer than the installation.
    var hasVerifiedRuntimeUpdate: Bool {
        latestSignedRuntimeRelease != nil
            && runtime.runtimeVersionStatus?.updateAvailable == true
    }

    private func syncCurrentDataHomeURL() {
        let updated = runtime.configuration.dshHome.standardizedFileURL
        guard updated != currentDataHomeURL.standardizedFileURL else { return }
        currentDataHomeURL = updated
        harnessProfiles = HarnessProfileStore(
            dshHome: updated,
            supportDirectory: supportDirectory
        )
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

    /// Reveals the current data home in Finder, creating it when missing.
    ///
    /// - Returns: `true` when Finder accepted the request.
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

    /// Opens a terminal scoped to the current app state.
    ///
    /// The generated `PATH` and `DSH_HOME` exist only inside the launched terminal
    /// tree; the user's shell configuration is untouched.
    @discardableResult
    func openRuntimeTerminal() -> Bool {
        let stateDirectory = supportDirectory
            .appendingPathComponent("Terminal", isDirectory: true)
            .appendingPathComponent(runtime.configuration.profileName, isDirectory: true)
        let configuration = RuntimeTerminalConfiguration(
            stateDirectory: stateDirectory,
            nodeExecutable: runtime.configuration.nodeExecutable,
            harnessEntry: runtime.configuration.harnessEntry,
            pnpmExecutable: runtime.configuration.pnpmExecutable,
            dshHome: currentDataHomeURL,
            workspace: settings.workspaceURL,
            profileName: runtime.configuration.profileName
        )
        do {
            let files = try terminalFileGenerator.prepare(configuration: configuration)
            let opened = NSWorkspace.shared.open(files.welcomeScript)
            if !opened {
                runtime.logs.log(component: "Terminal", level: "error", message: "unable to open generated terminal")
            }
            return opened
        } catch {
            runtime.logs.log(
                component: "Terminal",
                level: "error",
                message: LogRedactor.redact(error.localizedDescription)
            )
            return false
        }
    }

    /// Prompts for a workspace and restarts Harness against it.
    ///
    /// The previous workspace is restored when the Runtime fails to start with the new
    /// one, so a bad choice cannot leave the app unable to launch.
    ///
    /// - Returns: `true` when a workspace was admitted, `false` when the panel was
    ///   cancelled.
    /// - Throws: ``RuntimeError/workspaceFailure(_:)`` after a failed rollback.
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

    /// Creates a profile directory and republishes the model.
    ///
    /// - Parameter name: Profile name; validated by the profile store.
    /// - Throws: ``HarnessProfileStoreError`` when the name is invalid or taken.
    func createHarnessProfile(name: String) throws {
        _ = try harnessProfiles.create(name: name)
        objectWillChange.send()
    }

    /// Switches the active profile, restarting Harness when it is running.
    ///
    /// A profile that fails to start is rolled back to the last known good one.
    ///
    /// - Parameter name: Profile to activate.
    /// - Returns: `true` when the profile is active.
    /// - Throws: ``RuntimeError/processLaunchFailed(_:)`` after a failed rollback.
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

    /// Deletes a profile directory and republishes the model.
    ///
    /// - Parameter name: Profile to delete; protected profiles are rejected by the store.
    /// - Throws: ``HarnessProfileStoreError`` when the profile is protected or missing.
    func deleteHarnessProfile(name: String) throws {
        try harnessProfiles.delete(name: name)
        objectWillChange.send()
    }

    /// Exports one user preset to a `.dshpreset` archive.
    ///
    /// - Returns: The written archive, or `nil` when either panel was cancelled.
    /// - Throws: ``AgentPresetTransferError`` when the preset cannot be exported.
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

    /// Imports a preset archive after confirming the target identifier.
    ///
    /// - Returns: The installed identifier, or `nil` when the flow was cancelled.
    /// - Throws: ``AgentPresetTransferError`` when the archive is invalid or conflicts.
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

    /// Restores the previously installed Runtime build.
    ///
    /// - Throws: ``RuntimeUpdateError`` when no rollback target exists or the restore
    ///   fails.
    func rollbackRuntime() async throws {
        guard let coordinator = runtime.runtimeUpdateCoordinator else {
            throw RuntimeUpdateError.unavailable
        }
        try await coordinator.rollback()
        syncCurrentDataHomeURL()
    }

    /// Writes a redacted diagnostics archive.
    ///
    /// - Returns: The written archive URL.
    /// - Throws: ``DiagnosticsExportError`` when the bundle cannot be produced.
    func exportDiagnostics() async throws -> URL {
        let support = RuntimeLocator.applicationSupportDirectory()!
        let lines = await diagnosticLines()
        return try await DiagnosticsExporter.export(
            systemInfo: lines.joined(separator: "\n"),
            logsDirectory: support.appendingPathComponent("Logs", isDirectory: true),
            supportDirectory: support,
            evidence: diagnosticEvidence()
        )
    }

    private func diagnosticEvidence() -> [String: Data] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var evidence: [String: Data] = [:]
        func jsonValue<T>(_ value: T?) -> Any {
            value ?? NSNull()
        }

        let runtimeState: [String: Any] = [
            "state": runtime.state.displayName,
            "profile": runtime.configuration.profileName,
            "workspace": LogRedactor.redactPath(settings.workspaceURL.path),
            "dataHome": LogRedactor.redactPath(currentDataHomeURL.path),
            "nodeExecutable": LogRedactor.redactPath(runtime.configuration.nodeExecutable.path),
            "harnessEntry": LogRedactor.redactPath(runtime.configuration.harnessEntry.path),
            "pnpmExecutable": jsonValue(runtime.configuration.pnpmExecutable.map { LogRedactor.redactPath($0.path) }),
            "processID": jsonValue(runtime.currentProcessID),
            "processGeneration": runtime.currentProcessGeneration,
            "restartCount": runtime.restartCount,
            "lastTerminationStatus": jsonValue(runtime.lastTerminationStatus),
            "nodeVersion": jsonValue(runtime.nodeVersion),
            "harnessVersion": jsonValue(runtime.harnessVersion),
            "dataFormat": jsonValue(runtime.activeDataProfile?.dataFormatID),
            "error": jsonValue(runtime.lastError?.uiDescription),
            "recentStderr": runtime.recentCrashStderr
        ]
        if let data = try? JSONSerialization.data(withJSONObject: runtimeState, options: [.prettyPrinted, .sortedKeys]) {
            evidence["runtime-state.json"] = data
        }

        let profiles = harnessProfiles.profiles().map { profile in
            [
                "name": profile.name,
                "directory": LogRedactor.redactPath(profile.directory.path),
                "bundles": profile.bundles,
                "exists": profile.exists,
                "selectable": profile.selectable,
                "status": harnessProfiles.status(for: profile.name).rawValue,
                "recent": harnessProfiles.isRecentlyUsed(name: profile.name),
                "problem": jsonValue(profile.problem)
            ] as [String: Any]
        }
        if let data = try? JSONSerialization.data(withJSONObject: profiles, options: [.prettyPrinted, .sortedKeys]) {
            evidence["profiles.json"] = data
        }

        let presets = presetTransfer.summaries().map { preset in
            [
                "id": preset.id,
                "name": preset.name,
                "directory": LogRedactor.redactPath(preset.directory.path),
                "fileCount": preset.fileCount,
                "totalBytes": preset.totalBytes,
                "status": preset.status.rawValue,
                "recent": presetTransfer.isRecentlyUsed(id: preset.id),
                "problem": jsonValue(preset.problem)
            ] as [String: Any]
        }
        if let data = try? JSONSerialization.data(withJSONObject: presets, options: [.prettyPrinted, .sortedKeys]) {
            evidence["presets.json"] = data
        }

        let lifecycle = runtime.logs.entries.suffix(160).map { entry in
            [
                "timestamp": ISO8601DateFormatter().string(from: entry.timestamp),
                "level": entry.level,
                "component": entry.component,
                "message": entry.message
            ]
        }
        if let data = try? encoder.encode(lifecycle) {
            evidence["lifecycle.json"] = data
        }
        return evidence
    }

    /// Builds the redacted diagnostics summary.
    ///
    /// - Returns: One line per fact, in the order the settings page and the copied
    ///   summary present them.
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

    /// Copies the diagnostics summary to the general pasteboard.
    ///
    /// - Returns: `true` when the pasteboard accepted the text.
    @discardableResult
    func copyDiagnostics() async -> Bool {
        let diagnosticText = (await diagnosticLines()).joined(separator: "\n")

        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(diagnosticText, forType: .string)
    }

}
