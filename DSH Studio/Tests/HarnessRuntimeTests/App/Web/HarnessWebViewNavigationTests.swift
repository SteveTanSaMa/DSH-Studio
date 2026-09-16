//
//  HarnessWebViewNavigationTests.swift
//  DSH Studio
//

import XCTest

/// Guards the native WebView boundary against regressions that reopen external
/// URLs in Safari during startup.
final class HarnessWebViewNavigationTests: XCTestCase {
    func testExternalNavigationIsCancelledWithoutOpeningDefaultBrowser() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Web/WebView/HarnessWebViewNavigation.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("if isAllowed(url) {"))
        XCTAssertTrue(source.contains("decisionHandler(.allow)"))
        XCTAssertFalse(source.contains("NSWorkspace.shared.open"))
        XCTAssertFalse(source.contains("openExternalURLIfUserInitiated"))
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: "decisionHandler(.cancel)").count, 4)
    }
}
