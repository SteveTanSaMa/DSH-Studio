//
//  AppSettingsView.swift
//  DSH Studio
//

import AppKit
import DeepSeekRuntime
import SwiftUI

/// Native macOS settings for the Harness resources and support tools.
///
/// App preferences that already live in Harness's own settings page are absent
/// here on purpose.
///
/// App preferences that are already projected into Harness's own settings page
/// (workspace, data folder, chat width, notifications) are deliberately absent
/// here so a setting has exactly one home.
///
/// The page follows the macOS Settings convention: categories on the left and a
/// single grouped surface per category on the right. Every row is a native
/// control, so hover, focus, disabled, keyboard, and accessibility behavior all
/// come from the system instead of being re-created here.
@MainActor
struct AppSettingsView: View {
    /// Model whose Runtime, profiles, and presets the page edits.
    @ObservedObject var model: AppModel
    // Shared with the pane builders in the sibling `AppSettingsView+*.swift`
    // files, which keep each category's rows and copy readable on their own.
    /// Operation in flight, used to disable and show progress per row.
    @State var operation: SettingsOperation?
    /// Draft name for the create-profile field.
    @State var newProfileName = ""

    @State private var selection: SettingsPane?
    @State private var status: String?
    @State private var statusDismissTask: Task<Void, Never>?
    @State private var alert: SettingsAlert?

    /// Creates the settings page.
    ///
    /// - Parameters:
    ///   - model: App model to edit.
    ///   - initialPane: Category to show first; defaults to Harness Profiles.
    init(model: AppModel, initialPane: SettingsPane = .profiles) {
        self.model = model
        _selection = State(initialValue: initialPane)
    }

    /// Renders the sidebar, the selected category, and the single alert surface.
    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .background(SettingsWindowConfigurator())
        .toolbar(removing: .sidebarToggle)
        .frame(
            minWidth: SettingsDesign.windowMinWidth,
            idealWidth: SettingsDesign.windowIdealWidth,
            minHeight: SettingsDesign.windowMinHeight,
            idealHeight: SettingsDesign.windowIdealHeight
        )
        .alert(
            alert?.title ?? "",
            isPresented: alertIsPresented,
            presenting: alert
        ) { alert in
            alertActions(for: alert)
        } message: { alert in
            if let message = alert.message {
                Text(message)
            }
        }
    }

    // MARK: - Structure

    /// Applies the two window-level details the Settings page needs.
    ///
    /// 1. **Unified toolbar.** A `Settings` scene lays out a 32pt title row above a
    ///    56pt toolbar row, so the sidebar starts 88pt down and reads as a large
    ///    empty band. `.unified` merges both rows into the 52pt bar System
    ///    Settings uses. `windowToolbarStyle` on the scene has no effect on this
    ///    window on macOS 27, so the style is set on the window itself.
    /// 2. **No sidebar toggle.** The sidebar is the page's only navigation and is
    ///    never collapsed, so its toolbar button is removed. The item is installed
    ///    by the split view rather than by this view, so `toolbar(removing:)` does
    ///    not reach it. The public `.toggleSidebar` identifier is matched first and
    ///    the SwiftUI-prefixed spelling is accepted as a fallback; if a future
    ///    release renames it the button simply stays, so nothing can break.
    ///
    /// This is the only place the page touches AppKit.
    private struct SettingsWindowConfigurator: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView {
            let view = NSView(frame: .zero)
            context.coordinator.configure(view, attempt: 0)
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            context.coordinator.configure(nsView, attempt: 0)
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        @MainActor
        final class Coordinator {
            /// Retries a few times because the toolbar is built asynchronously.
            func configure(_ view: NSView, attempt: Int) {
                Task { @MainActor [weak view] in
                    guard let view else { return }
                    let styleApplied = Self.applyUnifiedToolbar(to: view.window)
                    let toggleRemoved = Self.removeSidebarToggle(in: view.window)
                    guard !(styleApplied && toggleRemoved), attempt < 5 else { return }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    self.configure(view, attempt: attempt + 1)
                }
            }

            private static func applyUnifiedToolbar(to window: NSWindow?) -> Bool {
                guard let window else { return false }
                guard window.toolbarStyle != .unified else { return true }
                window.toolbarStyle = .unified
                return false
            }

            private static func removeSidebarToggle(in window: NSWindow?) -> Bool {
                guard let toolbar = window?.toolbar else { return false }
                let toggle = toolbar.items.first { item in
                    item.itemIdentifier == .toggleSidebar
                        || item.itemIdentifier.rawValue.localizedCaseInsensitiveContains("togglesidebar")
                }
                guard let toggle, let index = toolbar.items.firstIndex(of: toggle) else {
                    return true
                }
                toolbar.removeItem(at: index)
                return false
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(SettingsPane.allCases) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .tag(pane)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(
            min: SettingsDesign.sidebarMinWidth,
            ideal: SettingsDesign.sidebarIdealWidth,
            max: SettingsDesign.sidebarMaxWidth
        )
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsDesign.sectionSpacing) {
                switch activePane {
                case .profiles:
                    profilePane
                case .presets:
                    presetPane
                case .runtime:
                    runtimePane
                case .diagnostics:
                    diagnosticPane
                }
            }
            .padding(.horizontal, SettingsDesign.contentHorizontalPadding)
            .padding(.top, SettingsDesign.contentTopPadding)
            .padding(.bottom, SettingsDesign.contentBottomPadding)
            .frame(maxWidth: SettingsDesign.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(SettingsDesign.paneBackground)
        // macOS puts a settings page's own name in the window title bar rather
        // than repeating it as a heading inside the scrolling content.
        .navigationTitle(activePane.title)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            statusBar
        }
    }

    /// Transient confirmation for finished work.
    ///
    /// Failures go to an alert instead, so this only ever carries neutral or
    /// success information.
    @ViewBuilder
    private var statusBar: some View {
        if let status {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 6) {
                    Text(status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.bar)
            .transition(.opacity)
        }
    }

    private var activePane: SettingsPane {
        selection ?? .profiles
    }

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: { alert != nil },
            set: { presented in
                if !presented { alert = nil }
            }
        )
    }

    @ViewBuilder
    private func alertActions(for alert: SettingsAlert) -> some View {
        switch alert {
        case .failure:
            Button("好", role: .cancel) { self.alert = nil }
        case .confirmProfileDeletion:
            Button("删除", role: .destructive) { deleteCurrentProfile() }
            Button("取消", role: .cancel) { self.alert = nil }
        }
    }

    // MARK: - Shared state

    /// True while a user-initiated operation or a Runtime transition is running.
    var isBusy: Bool {
        operation != nil || runtimeBusy
    }

    /// Whether the Runtime is mid-transition and its controls must stay disabled.
    var runtimeBusy: Bool {
        switch model.runtime.state {
        case .provisioning, .updating, .rollingBack, .launching, .starting, .stopping:
            return true
        case .idle, .ready, .failed, .terminated, .crashed:
            return false
        }
    }

    /// Version of the installed Runtime build, or `未知` when none is recorded.
    var installedRuntimeVersion: String {
        model.runtime.runtimeVersionStatus?.installed?.runtimeVersion ?? "未知"
    }

    /// The draft profile name with surrounding whitespace removed.
    var trimmedNewProfileName: String {
        newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the current profile may be deleted.
    ///
    /// The default profile is always protected, and no deletion is offered while an
    /// operation is running.
    var canDeleteCurrentProfile: Bool {
        !isBusy && model.runtime.configuration.profileName != HarnessProfileStore.defaultProfileName
    }

    /// Localized lifecycle state of the Runtime process.
    var installedRuntimeState: String {
        model.runtime.state.displayName
    }

    /// Localized comparison between the installed and pinned Runtime.
    var runtimeVersionState: String {
        model.runtime.runtimeVersionStatus?.displayName ?? "正在检查"
    }

    /// Explains why the update action is or is not available.
    var runtimeUpdateDescription: String {
        if let version = model.latestSignedHarnessVersion {
            return "可用版本 \(version)，验证通过后切换"
        }
        return "尚未获取可用版本，请先检查更新"
    }

    /// Formats one preset's identifier, file count, and size for its row.
    ///
    /// - Parameter summary: Preset to describe.
    /// - Returns: The secondary line shown under the preset name.
    func statusText(for summary: AgentPresetSummary) -> String {
        "\(summary.id) · \(summary.fileCount) 个文件 · \(ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file))"
    }

    /// Describes a profile's bundles, or its problem when it has one.
    ///
    /// - Parameter profile: Profile to describe.
    /// - Returns: The secondary line shown under the profile name.
    func profileDetail(_ profile: HarnessProfile) -> String {
        if let problem = profile.problem { return problem }
        if profile.bundles.isEmpty { return "无 Bundle 信息" }
        return profile.bundles.joined(separator: " · ")
    }

    /// Shows a transient status message and announces it to assistive technology.
    ///
    /// The message clears itself after a few seconds; failures use ``alert`` instead.
    ///
    /// - Parameter message: Text to show in the status bar.
    func showStatus(_ message: String) {
        statusDismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            status = message
        }
        // The status bar is transient, so assistive technology is told about
        // the result explicitly instead of having to observe the text.
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
        statusDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                status = nil
            }
        }
    }

    /// Selection binding that switches profiles through the model.
    ///
    /// The setter ignores the current profile, so re-selecting it cannot restart
    /// Harness.
    var activeProfileBinding: Binding<String> {
        Binding(
            get: { model.runtime.configuration.profileName },
            set: { name in selectProfile(name) }
        )
    }

    // MARK: - Actions

    private func selectProfile(_ name: String) {
        guard operation == nil, name != model.runtime.configuration.profileName else { return }
        operation = .selectingProfile
        Task { @MainActor in
            defer { operation = nil }
            do {
                _ = try await model.selectHarnessProfile(name: name)
                showStatus("Profile 已切换为「\(name)」")
            } catch {
                alert = .failure(error.localizedDescription)
            }
        }
    }

    /// Creates a profile from the draft name and clears the field on success.
    func createProfile() {
        let name = trimmedNewProfileName
        guard !name.isEmpty, operation == nil else { return }
        operation = .creatingProfile
        defer { operation = nil }
        do {
            try model.createHarnessProfile(name: name)
            newProfileName = ""
            showStatus("Profile「\(name)」已创建")
        } catch {
            alert = .failure(error.localizedDescription)
        }
    }

    /// Asks for confirmation before deleting the current profile.
    func requestProfileDeletion() {
        guard canDeleteCurrentProfile else { return }
        alert = .confirmProfileDeletion(model.runtime.configuration.profileName)
    }

    private func deleteCurrentProfile() {
        alert = nil
        let name = model.runtime.configuration.profileName
        operation = .deletingProfile
        defer { operation = nil }
        do {
            try model.deleteHarnessProfile(name: name)
            showStatus("Profile「\(name)」已删除")
        } catch {
            alert = .failure(error.localizedDescription)
        }
    }

    /// Runs the import panel flow and reports the installed preset.
    func importPreset() {
        guard operation == nil else { return }
        operation = .importingPreset
        Task { @MainActor in
            defer { operation = nil }
            do {
                guard let id = try await model.importAgentPreset() else { return }
                showStatus("Agent Preset 已导入：\(id)")
            } catch {
                alert = .failure(error.localizedDescription)
            }
        }
    }

    /// Runs the export panel flow and reports the written archive.
    func exportPreset() {
        guard operation == nil else { return }
        operation = .exportingPreset
        Task { @MainActor in
            defer { operation = nil }
            do {
                guard let url = try await model.exportAgentPreset() else { return }
                showStatus("Agent Preset 已导出：\(url.lastPathComponent)")
            } catch {
                alert = .failure(error.localizedDescription)
            }
        }
    }

    /// Refreshes the version comparison without downloading anything.
    func checkRuntime() {
        guard operation == nil else { return }
        operation = .checkingRuntimeUpdate
        Task { @MainActor in
            defer { operation = nil }
            _ = await model.checkRuntimeVersion()
            showStatus("Runtime 检查已完成")
        }
    }

    /// Activates the verified Runtime update.
    func updateRuntime() {
        guard operation == nil else { return }
        operation = .updatingRuntime
        Task { @MainActor in
            defer { operation = nil }
            do {
                try await model.updateRuntime()
                showStatus("Runtime 已更新")
            } catch {
                alert = .failure(error.localizedDescription)
            }
        }
    }

    /// Restores the previous Runtime build.
    func rollbackRuntime() {
        guard operation == nil else { return }
        operation = .rollingBackRuntime
        Task { @MainActor in
            defer { operation = nil }
            do {
                try await model.rollbackRuntime()
                showStatus("Runtime 已恢复上一版")
            } catch {
                alert = .failure(error.localizedDescription)
            }
        }
    }

    /// Writes a diagnostics archive and reports its file name.
    func exportDiagnostics() {
        guard operation == nil else { return }
        operation = .exportingDiagnostics
        Task { @MainActor in
            defer { operation = nil }
            do {
                let url = try await model.exportDiagnostics()
                showStatus("诊断包已保存：\(url.lastPathComponent)")
            } catch {
                alert = .failure(error.localizedDescription)
            }
        }
    }

    /// Copies the redacted diagnostics summary to the pasteboard.
    func copyDiagnostics() {
        guard operation == nil else { return }
        operation = .copyingDiagnostics
        Task { @MainActor in
            defer { operation = nil }
            if await model.copyDiagnostics() {
                showStatus("诊断信息已复制")
            } else {
                alert = .failure("无法复制诊断信息")
            }
        }
    }

    /// Opens the log directory in Finder.
    func openLogs() {
        guard operation == nil else { return }
        operation = .openingLogs
        defer { operation = nil }
        if model.openLogs() {
            showStatus("日志文件夹已打开")
        } else {
            alert = .failure("无法打开日志文件夹")
        }
    }

    /// Opens a terminal scoped to the current Runtime, profile, and workspace.
    func openTerminal() {
        guard operation == nil else { return }
        operation = .openingTerminal
        defer { operation = nil }
        if model.openRuntimeTerminal() {
            showStatus("DSH 终端已打开")
        } else {
            alert = .failure("无法打开 DSH 终端")
        }
    }
}

/// Categories shown in the Settings sidebar, in scan order.
///
/// The Harness resources the app manages come first, then maintenance. Preferences
/// owned by Harness's own settings page are not repeated here.
///
/// Harness-backed preferences belong to Harness's own settings page, so they are
/// intentionally not repeated as categories here.
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    /// Harness composition profiles: which one runs and what else is installed.
    case profiles
    /// User Agent Presets: import, export, and what is installed.
    case presets
    /// Runtime versions, status, and the maintenance actions.
    case runtime
    /// Diagnostics bundles, logs, and the scoped terminal.
    case diagnostics

    /// Identity for list rendering: the raw value.
    var id: String { rawValue }

    /// Sidebar label for the category.
    var title: String {
        switch self {
        case .profiles: return "Harness Profiles"
        case .presets: return "Agent Presets"
        case .runtime: return "Runtime"
        case .diagnostics: return "诊断与工具"
        }
    }

    /// SF Symbol used next to the sidebar label.
    var symbol: String {
        switch self {
        case .profiles: return "square.stack.3d.up"
        case .presets: return "slider.horizontal.3"
        case .runtime: return "arrow.triangle.2.circlepath"
        case .diagnostics: return "wrench.and.screwdriver"
        }
    }
}

/// A user-initiated operation that disables its controls while it runs.
///
/// Only the affected rows are disabled; the rest of the page stays interactive.
enum SettingsOperation: Hashable {
    /// Switching the active profile, which restarts Harness.
    case selectingProfile
    /// Creating a profile directory.
    case creatingProfile
    /// Deleting the current profile directory.
    case deletingProfile
    /// Importing a preset archive.
    case importingPreset
    /// Exporting a preset archive.
    case exportingPreset
    /// Refreshing the Runtime version comparison.
    case checkingRuntimeUpdate
    /// Activating a verified Runtime update.
    case updatingRuntime
    /// Restoring the previous Runtime build.
    case rollingBackRuntime
    /// Writing a diagnostics archive.
    case exportingDiagnostics
    /// Copying the diagnostics summary.
    case copyingDiagnostics
    /// Opening the log directory.
    case openingLogs
    /// Opening the scoped terminal.
    case openingTerminal
}

/// The one modal surface the page owns: a failure or a deletion confirmation.
///
/// Keeping both in a single presentation point avoids competing alerts when an
/// operation fails while another one is pending.
enum SettingsAlert: Identifiable {
    /// An operation failed; carries the message to show.
    case failure(String)
    /// Confirmation before deleting a profile; carries its name.
    case confirmProfileDeletion(String)

    /// Identity derived from the alert's content.
    var id: String {
        switch self {
        case .failure(let message): return "failure:\(message)"
        case .confirmProfileDeletion(let name): return "delete:\(name)"
        }
    }

    /// Localized alert title.
    var title: String {
        switch self {
        case .failure: return "操作失败"
        case .confirmProfileDeletion(let name): return "删除 Profile「\(name)」？"
        }
    }

    /// Optional localized explanation shown under the title.
    var message: String? {
        switch self {
        case .failure(let message): return message
        case .confirmProfileDeletion: return "删除后无法恢复，该 Profile 的目录与配置会被移除。"
        }
    }
}
