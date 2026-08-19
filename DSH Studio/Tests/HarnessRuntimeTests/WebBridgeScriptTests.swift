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
