//
//  HarnessWebViewNavigationTests.swift
//  DSH Studio
//

import XCTest

/// Guards the native WebView boundary.
///
/// A regression here would reopen external URLs in Safari during startup instead
/// of keeping navigation inside the embedded view.
final class HarnessWebViewNavigationTests: XCTestCase {
    /// An external URL is cancelled and never handed to the default browser.
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
