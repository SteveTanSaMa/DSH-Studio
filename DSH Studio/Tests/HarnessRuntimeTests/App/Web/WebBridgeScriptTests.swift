//
//  WebBridgeScriptTests.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import XCTest
@testable import DeepSeekHarness

/// Guards the injected scripts and the native boundaries they must respect.
///
/// These are contract tests: they fail if a script stops matching the selectors the
/// page depends on, starts touching app settings that must stay native, or if a
/// native surface loses a required control.
final class WebBridgeScriptTests: XCTestCase {
    /// The sidebar script resizes the grid and follows later attribute changes.
    func testCollapsedSidebarScriptResizesGridAndTracksAttributeChanges() {
        let source = HarnessLayoutWebBridge.source

        XCTAssertTrue(source.contains("grid-template-columns: 80px"))
        XCTAssertTrue(source.contains("width: 80px"))
        XCTAssertTrue(source.contains("min-width: 80px"))
        XCTAssertTrue(source.contains("data-sidebar-collapsed"))
        XCTAssertTrue(source.contains("attributeFilter"))
        XCTAssertTrue(source.contains("--deepseek-studio-details-width"))
        XCTAssertTrue(source.contains("[data-deepseek-studio-sidebar=\"collapsed\"] [class*=\"_regionArea\"] [class*=\"_rail\"]"))
        XCTAssertFalse(source.contains("[data-deepseek-studio-sidebar=\"collapsed\"] [class*=\"_rail\"] {"))
        XCTAssertTrue(source.contains("transform: scale(1.15) !important"))
        XCTAssertTrue(source.contains("align-items: center"))
        XCTAssertTrue(source.contains("padding-top: 32px !important"))
        XCTAssertTrue(source.contains("padding: 40px 10px 6px !important"))
        XCTAssertTrue(source.contains("let sidebarStateRetryTimer = 0"))
        XCTAssertTrue(source.contains("let sidebarStateRetryCount = 0"))
        XCTAssertTrue(source.contains("const sidebarEntrySelector"))
        XCTAssertTrue(source.contains("mutationChangesSidebarStructure"))
        XCTAssertTrue(source.contains("scheduleSidebarState();"))
    }

    /// The hero controls follow the composer card's measured bounds.
    func testHeroControlsTrackRenderedComposerCardBounds() {
        let source = HarnessLayoutWebBridge.source

        XCTAssertTrue(source.contains("[data-phase][class*=\"_root\"]"))
        XCTAssertTrue(source.contains("_heroWorkspaceRow"))
        XCTAssertTrue(source.contains("_workspaceRow"))
        XCTAssertTrue(source.contains("align-self: stretch !important"))
        XCTAssertTrue(source.contains("width: auto !important"))
        XCTAssertTrue(source.contains("--deepseek-studio-hero-card-left-inset"))
        XCTAssertTrue(source.contains("--deepseek-studio-hero-card-right-inset"))
        XCTAssertTrue(source.contains("[data-composer-card]"))
        XCTAssertTrue(source.contains("getBoundingClientRect()"))
        XCTAssertTrue(source.contains("cardBounds.left - rowBounds.left"))
        XCTAssertTrue(source.contains("rowBounds.right - cardBounds.right"))
        XCTAssertTrue(source.contains("new ResizeObserver(scheduleHeroAlignment)"))
        XCTAssertTrue(source.contains("window.addEventListener(\"resize\", scheduleHeroAlignment)"))
        XCTAssertTrue(source.contains("let heroStructureDirty = true"))
        XCTAssertTrue(source.contains("let heroEntries = []"))
        XCTAssertTrue(source.contains("[root, composer, card].forEach"))
        XCTAssertTrue(source.contains("const refreshHeroEntries"))
        XCTAssertTrue(source.contains("heroContainerSelector"))
        XCTAssertTrue(source.contains("mutationChangesHeroStructure"))
        XCTAssertTrue(source.contains("const scheduleSidebarState"))
        XCTAssertFalse(source.contains("[root, composer, row, card].forEach"))
        XCTAssertTrue(source.contains("var(--deepseek-studio-chat-max-width, 1000px)"))
        XCTAssertTrue(source.contains("max(748px, calc(100% - 96px))"))
        XCTAssertTrue(source.contains("max(0px, calc(100% - 32px))"))
        XCTAssertTrue(source.contains("min-width: 0 !important"))
        XCTAssertFalse(source.contains("clamp(748px, calc(100% - 96px)"))
        XCTAssertFalse(source.contains("--dsh-studio-hero-content-width"))
        XCTAssertFalse(source.contains(":has(> [data-composer-card])"))
        XCTAssertFalse(source.contains("flex: 0 0 var(--dsh-studio-hero-content-width)"))
        XCTAssertFalse(source.contains("transform: translateX"))
    }

    /// Assistant prose takes the native content width instead of Harness's own.
    func testAssistantProseUsesNativeContentWidth() {
        let source = HarnessLayoutWebBridge.source

        XCTAssertTrue(source.contains("[data-chat-flow-kind=\"assistant-step\"]"))
        XCTAssertTrue(source.contains("[class*=\"_body\"]"))
        XCTAssertTrue(source.contains("[class*=\"_markdown\"]"))
        XCTAssertTrue(source.contains("width: 100% !important"))
        XCTAssertTrue(source.contains("max-width: none !important"))
    }

    /// The conversation pane keeps its stacking order above the skin chrome.
    func testMaidAtelierConversationPaneIsAboveSkinChrome() {
        let source = HarnessLayoutWebBridge.source

        XCTAssertTrue(source.contains("body[data-dsh-maid-atelier]"))
        XCTAssertTrue(source.contains(":is([data-pane=\"conversation\"], [class*=\"centerCol\"])"))
        XCTAssertTrue(source.contains("position: relative !important"))
        XCTAssertTrue(source.contains("z-index: 1 !important"))
        XCTAssertFalse(source.contains("body[data-dsh-maid-atelier] [id=\"root\"]"))
    }

    /// Sidebar controls keep the native stacking order in the themed skin.
    func testMaidAtelierSidebarControlsKeepNativeStackingOrder() {
        let source = HarnessLayoutWebBridge.source

        XCTAssertTrue(source.contains(":is([data-pane=\"sidebar\"], [class*=\"sidebarCol\"])"))
        XCTAssertFalse(source.contains("z-index: 5 !important"))
        XCTAssertTrue(source.contains("[class*=\"_frame\"]"))
        XCTAssertTrue(source.contains("[class*=\"sidebarCol\"]"))
        XCTAssertTrue(source.contains("overflow: visible !important"))
        XCTAssertTrue(source.contains("[class*=\"_headerActions\"]"))
        XCTAssertTrue(source.contains("[class*=\"_logoRow\"]"))
        XCTAssertTrue(source.contains("[class*=\"_headerActions\"] [class*=\"_iconButton\"]"))
        XCTAssertTrue(source.contains("[class*=\"_logoRow\"] [class*=\"_toggle\"]"))
        XCTAssertTrue(source.contains("[role=\"tooltip\"]"))
        XCTAssertTrue(source.contains("z-index: 6 !important"))
        XCTAssertTrue(source.contains("z-index: 1200 !important"))
    }

    /// The WebView bridge projects only Harness's General settings.
    ///
    /// Profile, preset, Runtime, and diagnostics settings belong to the native window
    /// and must not reappear in the page.
    func testAppSettingsBridgeProjectsOnlyGeneralSettings() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Web/SettingsBridge")
        let source = try [
            "AppSettingsWebBridge.swift",
            "AppSettingsWebBridge+Behavior.swift",
            "AppSettingsWebBridge+Styles.swift",
            "AppSettingsWebBridge+CSS.swift",
            "AppSettingsWebBridge+Lifecycle.swift"
        ]
        .map { try String(contentsOf: sourceRoot.appendingPathComponent($0), encoding: .utf8) }
        .joined(separator: "\n")
        let settingsHandlerSource = try String(
            contentsOf: sourceRoot
                .deletingLastPathComponent()
                .appendingPathComponent("WebView/HarnessWebViewSettingsBridge.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("appSettings.openDataFolder"))
        XCTAssertTrue(source.contains("appSettings.chooseWorkspace"))
        XCTAssertFalse(source.contains("appSettings.openTerminal"))
        XCTAssertFalse(source.contains("appSettings.exportDiagnostics"))
        XCTAssertFalse(source.contains("appSettings.openLogs"))
        XCTAssertFalse(source.contains("appSettings.runtimeUpdate"))
        XCTAssertFalse(source.contains("appSettings.createProfile"))
        XCTAssertFalse(source.contains("appSettings.selectProfile"))
        XCTAssertFalse(source.contains("appSettings.importPreset"))
        XCTAssertFalse(source.contains("appSettings.exportPreset"))
        XCTAssertFalse(source.contains("latestHarnessVersion"))
        XCTAssertFalse(source.contains("harnessProfiles"))
        XCTAssertFalse(source.contains("agentPresets"))
        XCTAssertTrue(source.contains("placeholder=\"748–2400\""))
        XCTAssertTrue(source.contains("选择工作区"))
        XCTAssertTrue(source.contains("data-app-i18n=\"dataFolder\">数据文件夹"))
        XCTAssertLessThan(
            source.range(of: "data-app-i18n=\"workspace\"")!.lowerBound,
            source.range(of: "data-app-i18n=\"dataFolder\"")!.lowerBound
        )
        XCTAssertFalse(source.contains("workspaceDetail"))
        XCTAssertTrue(source.contains("dsh-studio-app-settings-section-divider"))
        XCTAssertTrue(source.contains("border-bottom: 1px solid var(--dsw-alias-border-l2)"))
        XCTAssertTrue(source.contains("const messages ="))
        XCTAssertTrue(source.contains("Chat content width"))
        XCTAssertTrue(source.contains("data-app-i18n=\"notifications\">通知"))
        XCTAssertTrue(source.contains("data-app-i18n=\"turnCompletionNotification\">轮次完成通知"))
        XCTAssertTrue(source.contains("设置 DSH Studio 完成后何时提醒您"))
        XCTAssertTrue(source.contains("Choose when to be notified after DSH Studio finishes"))
        XCTAssertTrue(source.contains("data-app-i18n=\"permissionNotifications\">启用权限通知"))
        XCTAssertTrue(source.contains("在需要通知权限时显示提醒"))
        XCTAssertTrue(source.contains("data-app-i18n=\"questionNotifications\">启用问题通知"))
        XCTAssertTrue(source.contains("需要输入才能继续时显示提醒"))
        XCTAssertTrue(source.contains("createGeneralBlock"))
        XCTAssertTrue(source.contains("attachGeneralBlock"))
        XCTAssertTrue(source.contains("dataset.slot = \"settings.general.item\""))
        XCTAssertFalse(source.contains("settings.section"))
        XCTAssertFalse(source.contains("dsh-studio-settings-nav"))
        XCTAssertFalse(source.contains("deepseekStudioSettingsSection"))
        XCTAssertFalse(source.contains("data-deepseek-studio-settings-content-active"))
        XCTAssertFalse(source.contains("createStudioBlock"))
        XCTAssertFalse(source.contains("studioBlock"))
        XCTAssertFalse(source.contains("settingsSectionIds"))
        XCTAssertTrue(source.contains("dsh-studio-app-settings-notification-row"))
        XCTAssertTrue(source.contains("dsh-studio-app-settings-notification-row-last"))
        XCTAssertTrue(source.contains("width: 52px;"))
        XCTAssertTrue(source.contains("height: 36px;"))
        XCTAssertTrue(source.contains("width: 32px;"))
        XCTAssertTrue(source.contains("height: 20px;"))
        XCTAssertTrue(source.contains("width: 16px;"))
        XCTAssertTrue(source.contains("height: 16px;"))
        XCTAssertTrue(source.contains("transform: translateX(12px);"))
        XCTAssertTrue(source.contains("turnCompletionNotification"))
        XCTAssertTrue(source.contains("permissionNotificationsEnabled"))
        XCTAssertTrue(source.contains("questionNotificationsEnabled"))
        XCTAssertTrue(source.contains("role=\"switch\""))
        XCTAssertTrue(source.contains("aria-haspopup=\"listbox\""))
        XCTAssertTrue(source.contains("data-app-option=\"whenNotFocused\""))
        XCTAssertFalse(source.contains("<select"))
        XCTAssertFalse(source.contains("type=\"checkbox\""))
        XCTAssertTrue(source.contains("whenNotFocused"))
        XCTAssertTrue(source.contains("仅在未聚焦时"))
        XCTAssertTrue(source.contains("document.documentElement?.lang"))
        XCTAssertTrue(source.contains("attributeFilter: [\"lang\", \"class\"]"))
        XCTAssertTrue(source.contains("工作区"))
        XCTAssertTrue(source.contains("数据文件夹"))
        XCTAssertTrue(source.contains("data-app-i18n=\"notifications\">通知"))
        XCTAssertFalse(source.contains("dsh-studio-app-settings-version-actions"))
        XCTAssertFalse(source.contains("dsh-studio-app-settings-resource-list"))
        XCTAssertFalse(source.contains("dsh-studio-app-settings-status-badge"))
        XCTAssertFalse(settingsHandlerSource.contains("case \"appSettings.openTerminal\":"))
        XCTAssertFalse(settingsHandlerSource.contains("terminal-open-failed"))
        XCTAssertFalse(settingsHandlerSource.contains("Agent Preset 已导入"))
        XCTAssertFalse(settingsHandlerSource.contains("Agent Preset 已导出"))
        XCTAssertFalse(settingsHandlerSource.contains("copyDiagnostics"))

    }

    /// The native settings scene owns every app-level setting.
    func testNativeSettingsSceneOwnsAppLevelSettings() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/App")
        let appSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("Core/DeepSeekHarnessSliceApp.swift"),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("Core/AppSettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(appSource.contains("Settings {"))
        XCTAssertTrue(appSource.contains("AppSettingsView(model: AppDelegate.sharedModel)"))
        XCTAssertTrue(settingsSource.contains("Harness Profiles"))
        XCTAssertTrue(settingsSource.contains("Agent Presets"))
        XCTAssertTrue(settingsSource.contains("Runtime"))
        XCTAssertTrue(settingsSource.contains("诊断与工具"))
    }

    /// Guards the Settings window contract.
    ///
    /// One sidebar category per concern, the macOS 26 settings metrics (46pt rows,
    /// 12pt group radius, 13/11pt type) with no decoration layered on top, and no
    /// setting that Harness's own settings page already projects.
    func testSettingsWindowUsesSystemSettingsMetricsAndNativeControls() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/App")
        let source = try [
            "Core/AppSettingsView.swift",
            "Core/Settings/SettingsDesign.swift",
            "Core/Settings/AppSettingsView+Profiles.swift",
            "Core/Settings/AppSettingsView+Presets.swift",
            "Core/Settings/AppSettingsView+Runtime.swift",
            "Core/Settings/AppSettingsView+Diagnostics.swift"
        ]
        .map { try String(contentsOf: appRoot.appendingPathComponent($0), encoding: .utf8) }
        .joined(separator: "\n")

        // Only the categories this app owns appear in the sidebar.
        for pane in ["case profiles", "case presets", "case runtime", "case diagnostics"] {
            XCTAssertTrue(source.contains(pane), "missing settings pane \(pane)")
        }
        XCTAssertTrue(source.contains("NavigationSplitView"))
        XCTAssertTrue(source.contains(".listStyle(.sidebar)"))
        XCTAssertTrue(source.contains(".navigationTitle(activePane.title)"))
        XCTAssertTrue(source.contains("SettingsGroup("))

        // Preferences that Harness's own settings page already projects are not
        // duplicated in the native window: one setting, one home.
        for duplicated in ["chatContentMaxWidth", "workspaceURL", "currentDataHomeURL",
                           "turnCompletionNotification", "permissionNotificationsEnabled",
                           "questionNotificationsEnabled"] {
            XCTAssertFalse(
                source.contains(duplicated),
                "\(duplicated) belongs to Harness's settings page, not the native window"
            )
        }

        // macOS 26 settings surface metrics.
        XCTAssertTrue(source.contains("static let rowMinHeight: CGFloat = 46"))
        XCTAssertTrue(source.contains("static let groupCornerRadius: CGFloat = 12"))
        XCTAssertTrue(source.contains("static let titleFont = Font.body.weight(.medium)"))
        XCTAssertTrue(source.contains("static let detailFont = Font.subheadline"))
        XCTAssertTrue(source.contains("static let headerFont = Font.subheadline.weight(.bold)"))
        XCTAssertTrue(source.contains(".fill(SettingsDesign.groupFill)"))

        // The group surface follows the effective appearance instead of being
        // frozen to the one that was current when the value was created.
        XCTAssertTrue(source.contains("static let groupFill = adaptive("))
        XCTAssertTrue(source.contains("static let separator = adaptive("))

        // Every row action shares one width, and the sidebar cannot be collapsed.
        XCTAssertTrue(source.contains("static let actionButtonLabelWidth"))
        XCTAssertTrue(source.contains("frame(minWidth: SettingsDesign.actionButtonLabelWidth)"))
        XCTAssertTrue(source.contains("SettingsWindowConfigurator"))
        XCTAssertTrue(source.contains("itemIdentifier == .toggleSidebar"))
        XCTAssertTrue(source.contains("window.toolbarStyle = .unified"))

        // Destructive removal is confirmed and unreachable for the default profile.
        XCTAssertTrue(source.contains("case confirmProfileDeletion"))
        XCTAssertTrue(source.contains("canDeleteCurrentProfile"))
        XCTAssertTrue(source.contains("HarnessProfileStore.defaultProfileName"))

        // Hierarchy comes from spacing, type, and one low-contrast fill.
        XCTAssertFalse(source.contains("LinearGradient"))
        XCTAssertFalse(source.contains(".shadow("))
        XCTAssertFalse(source.contains(".borderedProminent"))
        XCTAssertFalse(source.contains(".glassEffect("))
        XCTAssertFalse(source.contains("NSVisualEffectView"))

        // The window still opens on a category this app owns.
        XCTAssertTrue(source.contains("initialPane: SettingsPane = .profiles"))
    }

    /// The app menu covers the expected App, File, View, and Help actions.
    func testNativeMenuCommandsCoverAppFileViewAndHelpActions() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Core/DeepSeekHarnessSliceApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("Settings {"))
        XCTAssertFalse(source.contains("CommandMenu(\"DSH Studio\")"))
        XCTAssertTrue(source.contains("检查 Runtime 更新"))
        XCTAssertTrue(source.contains("打开 DSH 终端"))
        XCTAssertTrue(source.contains("打开工作区"))
        XCTAssertTrue(source.contains("打开数据文件夹"))
        XCTAssertTrue(source.contains("关闭窗口"))
        XCTAssertTrue(source.contains("显示/隐藏侧边栏"))
        XCTAssertTrue(source.contains("刷新 Harness"))
        XCTAssertTrue(source.contains("进入全屏"))
        XCTAssertTrue(source.contains("DSH Studio 帮助"))
        XCTAssertTrue(source.contains("打开日志文件夹"))
        XCTAssertTrue(source.contains("导出诊断包"))
        XCTAssertTrue(source.contains("复制诊断信息"))
    }

    /// The menu bridge exposes the sidebar toggle and native controls.
    func testHarnessMenuBridgeExposesSidebarToggleAndNativeControls() throws {
        let behaviorURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Harness/Web/Layout/HarnessLayoutWebBridge+Behavior.swift")
        let webViewURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Web/HarnessWebView.swift")
        let behaviorSource = try String(contentsOf: behaviorURL, encoding: .utf8)
        let webViewSource = try String(contentsOf: webViewURL, encoding: .utf8)

        XCTAssertTrue(behaviorSource.contains("__deepseekStudioToggleSidebar"))
        XCTAssertTrue(behaviorSource.contains("toggle.click()"))
        XCTAssertTrue(webViewSource.contains("reloadLiveWebViews"))
        XCTAssertTrue(webViewSource.contains("toggleSidebarOnLiveWebViews"))
        XCTAssertTrue(webViewSource.contains("evaluateJavaScript"))
    }

    /// The market's restart is routed through the app-owned Runtime.
    func testPluginMarketRestartIsRoutedThroughNativeRuntime() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/App")
        let bridgeSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("Web/WebView/PluginMarketRestartWebBridge.swift"),
            encoding: .utf8
        )
        let webViewSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("Web/HarnessWebView.swift"),
            encoding: .utf8
        )
        let handlerSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("Web/WebView/HarnessWebViewSettingsBridge.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(bridgeSource.contains("/dsh-market/restart"))
        XCTAssertTrue(bridgeSource.contains("pluginMarket.restart"))
        XCTAssertTrue(bridgeSource.contains("status: 202"))
        XCTAssertTrue(webViewSource.contains("PluginMarketRestartWebBridge.source"))
        XCTAssertTrue(handlerSource.contains("PluginMarketRestartWebBridge.messageType"))
        XCTAssertTrue(handlerSource.contains("restartRuntimeForPluginMarket"))
    }

    /// Workspace groups use the list width that remains beside the scrollbar.
    func testWorkspaceGroupsUseAvailableListWidthAroundScrollbar() {
        let source = HarnessLayoutWebBridge.source

        XCTAssertTrue(source.contains("[class*=\"_groupSection\"]"))
        XCTAssertTrue(source.contains("[class*=\"_groupSection\"] > *"))
        XCTAssertTrue(source.contains("[class*=\"_groupSection\"] [role=\"treeitem\"]"))
        XCTAssertTrue(source.contains("[class*=\"_sessionOverflowButton\"]"))
        XCTAssertTrue(source.contains("width: calc(100% - var(--dsh-session-list-scrollbar-width, 8px)) !important"))
        XCTAssertTrue(source.contains("width: 100% !important"))
        XCTAssertTrue(source.contains("max-width: 100% !important"))
        XCTAssertTrue(source.contains("box-sizing: border-box !important"))
    }

    /// The export script suppresses only Harness's own download feedback.
    func testSessionExportScriptInterceptsOnlyHarnessDownloadFeedback() {
        let source = SessionLogExportWebBridge.interceptDialogScript

        XCTAssertTrue(source.contains("__deepseekStudioSessionExportInterceptInstalled"))
        XCTAssertTrue(source.contains("正在导出 Session"))
        XCTAssertTrue(source.contains("Session 导出已开始下载"))
        XCTAssertTrue(source.contains("Session download started"))
        XCTAssertTrue(source.contains("feedbackTitles"))
        XCTAssertTrue(source.contains("successTitles"))
        XCTAssertTrue(source.contains("hiddenSelector"))
        XCTAssertTrue(source.contains("dismissSelector"))
        XCTAssertTrue(source.contains("modalRootSelector"))
        XCTAssertTrue(source.contains("role=\"presentation\"]:has(> [role=\"dialog\"]"))
        XCTAssertTrue(source.contains("display: none !important"))
        XCTAssertTrue(source.contains("style.setProperty(\"display\", \"none\", \"important\")"))
        XCTAssertTrue(source.contains("closest('[role=\"presentation\"]')"))
        XCTAssertTrue(source.contains("Close"))
        XCTAssertTrue(source.contains("role=\"dialog\""))
        XCTAssertTrue(source.contains("MutationObserver"))
        XCTAssertTrue(source.contains("button.click()"))
        XCTAssertFalse(source.contains("Session 导出失败"))
        XCTAssertFalse(source.contains("Session export failed"))
    }

    /// Diagnostics evidence stays bounded and redacted at the exporter boundary.
    func testDiagnosticsExporterContractUsesBoundedRedactedEvidence() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Core")
        let source = try String(
            contentsOf: sourceRoot.appendingPathComponent("DiagnosticsExporter.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("static func prepareStaging"))
        XCTAssertTrue(source.contains("LogRedactor.redact(systemInfo)"))
        XCTAssertTrue(source.contains("sanitizeText: true"))
        XCTAssertTrue(source.contains("maxEvidenceBytes"))
        XCTAssertTrue(source.contains("maxTotalStagingBytes"))
        XCTAssertTrue(source.contains("allowedEvidenceNames"))
        XCTAssertTrue(source.contains("isNonSymlinkRegularFile"))
        XCTAssertTrue(source.contains("DiagnosticsExportError.unsafeInput"))
    }
}
