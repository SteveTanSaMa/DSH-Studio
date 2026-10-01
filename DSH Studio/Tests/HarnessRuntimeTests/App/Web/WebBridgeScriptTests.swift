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
    /// Repository root, resolved from this file's location.
    ///
    /// The plugin package and the Swift sources live in different subtrees, so tests
    /// that cross between them resolve both from here instead of from the App sources.
    private var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            url.deleteLastPathComponent()
        }
        return url
    }

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

    /// The layout script restores a stored sidebar width and reports later drags.
    ///
    /// The Harness layout store is transient, so the app is the only side that can carry
    /// a dragged width across launches; this is the whole contract between the two.
    func testSidebarWidthScriptRestoresStoredWidthAndReportsDrags() {
        let source = HarnessLayoutWebBridge.source

        XCTAssertTrue(source.contains("window.__deepseekStudioSidebarWidth"))
        XCTAssertTrue(source.contains("[class*=\"_handle\"]"))
        XCTAssertTrue(
            source.contains("Element.prototype.setPointerCapture"),
            "replaying the drag needs the capture call stubbed for a synthetic pointer"
        )
        XCTAssertTrue(source.contains("\"pointerdown\""))
        XCTAssertTrue(source.contains("\"pointermove\""))
        XCTAssertTrue(source.contains("\"pointerup\""))
        XCTAssertTrue(source.contains("data-sidebar-collapsed"))
        XCTAssertTrue(source.contains("\"preference.sync\""))
        XCTAssertTrue(source.contains("\"sidebarWidth\""))
        XCTAssertTrue(
            source.contains("deepseekStudio"),
            "the report goes through the app's own message handler"
        )
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

    /// Settings are provided by the first-party Harness plugin, not DOM injection.
    func testSettingsAreMountedByFirstPartyPlugin() throws {
        let plugin = repositoryRoot.appendingPathComponent("Plugins/dsh-studio-settings")
        let manifest = try String(
            contentsOf: plugin.appendingPathComponent("package.json"),
            encoding: .utf8
        )
        let registration = try String(
            contentsOf: plugin.appendingPathComponent("src/registration.js"),
            encoding: .utf8
        )
        XCTAssertTrue(manifest.contains("\"settings.section\"") == false)
        XCTAssertTrue(manifest.contains("\"dsh-studio-settings\""))
        XCTAssertTrue(registration.contains("ctx.slots.inject(\"settings.section\""))
        XCTAssertTrue(registration.contains("ctx.configForms.whileServed"))
        XCTAssertFalse(registration.contains("querySelector"))
    }

    /// The page's browser bundle ships and registers under the package name.
    ///
    /// Harness's module table keys a bundle by the package name it declares, so a
    /// missing or renamed `lib/client.js` leaves the settings page silently absent
    /// from the Harness dialog. The bundle is also required to import React and the
    /// primitives from the shell's shared table instead of bundling a second copy.
    func testSettingsPageBundleRegistersUnderItsPackageName() throws {
        let plugin = repositoryRoot.appendingPathComponent("Plugins/dsh-studio-settings")
        let manifest = try String(
            contentsOf: plugin.appendingPathComponent("package.json"),
            encoding: .utf8
        )
        let bundle = try String(
            contentsOf: plugin.appendingPathComponent("lib/client.js"),
            encoding: .utf8
        )

        XCTAssertTrue(manifest.contains("\"./client\": \"./lib/client.js\""))
        XCTAssertTrue(bundle.contains("__ModuleLoader__.load({id:\"dsh-studio-settings\""))
        XCTAssertTrue(bundle.hasSuffix("return module.exports;}});\n"))
        XCTAssertTrue(bundle.contains("require(\"react\")"))
        XCTAssertTrue(bundle.contains("require(\"@deepseek-ai/dsh-client-ui-primitives\")"))
        // A marker from the shipped stylesheet: proves the artifact was rebuilt from
        // the current sources rather than left behind by an earlier build.
        XCTAssertTrue(bundle.contains("dshStudioSection"))
    }

    /// Every action the settings page sends has a native handler, and the native side
    /// adds no action the page cannot reach.
    func testStudioActionContractIsComplete() throws {
        let actions = [
            "profile.list", "profile.create", "profile.select", "profile.delete",
            "workspace.choose", "data.open", "terminal.open", "logs.open",
            "preset.import", "preset.export",
            "runtime.check", "runtime.update", "runtime.rollback",
            "diagnostics.copy", "diagnostics.export", "preference.sync"
        ]
        let bridge = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "DSH Studio/Sources/App/Web/WebView/HarnessWebViewSettingsBridge.swift"
            ),
            encoding: .utf8
        )
        let bundle = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Plugins/dsh-studio-settings/lib/client.js"),
            encoding: .utf8
        )

        for action in actions {
            XCTAssertTrue(bridge.contains("case \"\(action)\""), "no native handler for \(action)")
            XCTAssertTrue(bundle.contains("\"\(action)\""), "settings page never sends \(action)")
        }
    }

    /// The page's message handler is registered with the content controller.
    ///
    /// `window.webkit.messageHandlers.<name>` only exists once the WebView adds the
    /// coordinator to its user content controller, so a missing registration turns
    /// every native operation into an instant "bridge unavailable" failure.
    func testNativeBridgeRegistersTheScriptMessageHandler() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Web/HarnessWebView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("configuration.userContentController.add("))
        XCTAssertTrue(source.contains("name: PluginMarketRestartWebBridge.messageHandlerName"))
        XCTAssertTrue(source.contains("removeScriptMessageHandler(forName: PluginMarketRestartWebBridge.messageHandlerName)"))
    }

    /// The app menu opens Harness's own settings dialog rather than a native window.
    func testSettingsMenuCommandPressesTheHarnessTrigger() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let behavior = try String(
            contentsOf: sourceRoot.appendingPathComponent("Harness/Web/Layout/HarnessLayoutWebBridge+Behavior.swift"),
            encoding: .utf8
        )
        let webView = try String(
            contentsOf: sourceRoot.appendingPathComponent("App/Web/HarnessWebView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(behavior.contains("__deepseekStudioOpenSettings"))
        XCTAssertTrue(behavior.contains("[data-slot=\"sidebar.settings\"]"))
        XCTAssertTrue(behavior.contains("[data-shortcut-modal=\"settings\"]"))
        XCTAssertTrue(behavior.contains("trigger.click()"))
        XCTAssertTrue(webView.contains("__deepseekStudioOpenSettings"))
    }

    /// The chat width preference is replayed into every freshly loaded page.
    func testChatContentWidthIsReplayedIntoLoadedPages() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let webView = try String(
            contentsOf: sourceRoot.appendingPathComponent("App/Web/HarnessWebView.swift"),
            encoding: .utf8
        )
        let navigation = try String(
            contentsOf: sourceRoot.appendingPathComponent("App/Web/WebView/HarnessWebViewNavigation.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(webView.contains("applyChatContentMaxWidthOnLiveWebViews"))
        XCTAssertTrue(webView.contains("__deepseekStudioSetChatContentMaxWidth"))
        XCTAssertTrue(navigation.contains("__deepseekStudioSetChatContentMaxWidth"))
        XCTAssertTrue(navigation.contains("model.settings.chatContentMaxWidth"))
    }

    /// There is no independent native Settings scene or command fallback.
    func testNativeSettingsSurfaceIsRemoved() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Core/DeepSeekHarnessSliceApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(source.contains("Settings {"))
        XCTAssertFalse(source.contains("showSettingsWindow"))
        XCTAssertFalse(source.contains("CommandGroup(replacing: .appSettings)"))
        XCTAssertTrue(source.contains("openSettingsOnLiveWebViews"))
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

        XCTAssertTrue(source.contains("keyboardShortcut(\",\", modifiers: [.command])"))
        XCTAssertTrue(source.contains("openSettingsOnLiveWebViews"))
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

    /// Web Inspector access stays behind a native, explicitly controlled WebKit flag.
    func testWebViewInspectionUsesPublicInspectableFlag() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Web/HarnessWebView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("#if DEBUG"))
        XCTAssertTrue(source.contains("defaultWebInspectionEnabled = false"))
        XCTAssertTrue(source.contains("webView.isInspectable = Self.webInspectionEnabled"))
        XCTAssertTrue(source.contains("$0.value?.isInspectable = enabled"))
        XCTAssertFalse(source.contains("setValue(true, forKey: \"developerExtrasEnabled\")"))
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

    /// Nested Harness scrollports keep their own boundaries without global event interception.
    func testNestedScrollportsIsolateOverscroll() {
        let source = HarnessLayoutWebBridge.source

        XCTAssertTrue(source.contains("[data-conversation-scroll]"))
        XCTAssertTrue(source.contains("overscroll-behavior-y: none !important"))
        XCTAssertTrue(source.contains("[data-input-scroll]"))
        XCTAssertTrue(source.contains("overscroll-behavior-y: contain !important"))
        XCTAssertTrue(source.contains("inputScrollSelector"))
        XCTAssertTrue(source.contains("installInputScrollBoundaryGuard"))
        XCTAssertTrue(source.contains("element.addEventListener(\"wheel\""))
        XCTAssertTrue(source.contains("capture: true"))
        XCTAssertTrue(source.contains("stopImmediatePropagation()"))
        XCTAssertTrue(source.contains("syncInputScrollBoundaryGuards"))
        XCTAssertFalse(source.contains("preventDefault"))
        XCTAssertFalse(source.contains("document.addEventListener(\"wheel\""))
        XCTAssertFalse(source.contains("window.addEventListener(\"wheel\""))
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
