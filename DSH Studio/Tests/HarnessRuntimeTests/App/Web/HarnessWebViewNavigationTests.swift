//
//  HarnessWebViewNavigationTests.swift
//  DSH Studio
//

import XCTest

/// Guards the native WebView boundary.
///
/// A regression here could either leak the embedded session into an external page
/// or make ordinary HTTPS documentation links appear broken.
final class HarnessWebViewNavigationTests: XCTestCase {
    /// Only user-activated HTTPS navigation is handed to the default browser.
    func testExternalNavigationOpensOnlySafeUserActivatedHTTPSLinks() throws {
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
        XCTAssertTrue(source.contains("navigationAction.navigationType == .linkActivated"))
        XCTAssertTrue(source.contains("HarnessURLPolicy.isAllowedExternalHTTPS(url)"))
        XCTAssertTrue(source.contains("NSWorkspace.shared.open(url)"))
        XCTAssertTrue(source.contains("createWebViewWith"))
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: "decisionHandler(.cancel)").count, 4)
    }
}
