//
//  WebBridgeScriptTests.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import XCTest
@testable import DeepSeekHarness

/// Guards the stable selectors and behaviors used by injected WebView scripts.
final class WebBridgeScriptTests: XCTestCase {
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
    }

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
        XCTAssertFalse(source.contains("--dsh-studio-hero-content-width"))
        XCTAssertFalse(source.contains(":has(> [data-composer-card])"))
        XCTAssertFalse(source.contains("flex: 0 0 var(--dsh-studio-hero-content-width)"))
        XCTAssertFalse(source.contains("transform: translateX"))
    }

    func testAssistantProseUsesNativeContentWidth() {
        let source = HarnessLayoutWebBridge.source

        XCTAssertTrue(source.contains("[data-chat-flow-kind=\"assistant-step\"]"))
        XCTAssertTrue(source.contains("[class*=\"_body\"]"))
        XCTAssertTrue(source.contains("[class*=\"_markdown\"]"))
        XCTAssertTrue(source.contains("width: 100% !important"))
        XCTAssertTrue(source.contains("max-width: none !important"))
    }

    func testMaidAtelierConversationPaneIsAboveSkinChrome() {
        let source = HarnessLayoutWebBridge.source

        XCTAssertTrue(source.contains("body[data-dsh-maid-atelier]"))
        XCTAssertTrue(source.contains(":is([data-pane=\"conversation\"], [class*=\"centerCol\"])"))
        XCTAssertTrue(source.contains("position: relative !important"))
        XCTAssertTrue(source.contains("z-index: 1 !important"))
        XCTAssertFalse(source.contains("body[data-dsh-maid-atelier] [id=\"root\"]"))
    }

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

    func testAppSettingsBridgeKeepsRuntimeDetailsInternal() throws {
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

        XCTAssertTrue(source.contains("appSettings.openDataFolder"))
        XCTAssertTrue(source.contains("appSettings.copyDiagnostics"))
        XCTAssertTrue(source.contains("appSettings.runtimeUpdate"))
        XCTAssertTrue(source.contains("latestHarnessVersion"))
        XCTAssertFalse(source.contains("availableHarnessVersion"))
        XCTAssertFalse(source.contains("harnessStatus"))
        XCTAssertTrue(source.contains("placeholder=\"748–2400\""))
        XCTAssertFalse(source.contains("选择目录"))
        XCTAssertTrue(source.contains("data-app-i18n=\"dataFolder\">数据文件夹"))
        XCTAssertTrue(source.contains("data-app-i18n=\"harnessVersion\">Harness版本"))
        XCTAssertTrue(source.contains("dsh-studio-app-settings-section-divider"))
        XCTAssertTrue(source.contains("border-bottom: 1px solid var(--dsw-alias-border-l2)"))
        XCTAssertTrue(source.contains("const messages ="))
        XCTAssertTrue(source.contains("Chat content width"))
        XCTAssertTrue(source.contains("data-app-i18n=\"notifications\">通知"))
        XCTAssertTrue(source.contains("data-app-i18n=\"turnCompletionNotification\">轮次完成通知"))
        XCTAssertTrue(source.contains("设置 ChatGPT 完成后何时提醒您"))
        XCTAssertTrue(source.contains("data-app-i18n=\"permissionNotifications\">启用权限通知"))
        XCTAssertTrue(source.contains("在需要通知权限时显示提醒"))
        XCTAssertTrue(source.contains("data-app-i18n=\"questionNotifications\">启用问题通知"))
        XCTAssertTrue(source.contains("需要输入才能继续时显示提醒"))
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
        XCTAssertTrue(source.contains("attributeFilter: [\"lang\"]"))
        XCTAssertTrue(source.contains("打开日志文件夹"))
        XCTAssertTrue(source.contains("dsh-studio-app-settings-version-actions"))
        XCTAssertFalse(source.contains("当前工作区"))
        XCTAssertFalse(source.contains("当前数据文件夹"))
        XCTAssertFalse(source.contains("<div class=\"dsh-studio-app-settings-section-title\">诊断</div>"))
        XCTAssertFalse(source.contains("appSettings.chooseWorkspace"))
        XCTAssertFalse(source.contains("appSettings.runtimeCheck"))
        XCTAssertFalse(source.contains("appSettings.selectDataProfile"))
        XCTAssertFalse(source.contains("appSettings.runtimeCreateProfile"))
        XCTAssertFalse(source.contains("runtimeAvailableDataFormatID"))
        XCTAssertFalse(source.contains("Node 版本"))
        XCTAssertFalse(source.contains("Runtime 版本"))

    }

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
}
