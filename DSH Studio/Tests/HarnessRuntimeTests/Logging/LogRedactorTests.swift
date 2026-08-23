//
//  LogRedactorTests.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import XCTest
@testable import DeepSeekLogging

/// Ensures secrets and absolute paths never survive the log boundary.
final class LogRedactorTests: XCTestCase {
    func testRedactsHomeDirectoryFromTextAndPaths() {
        let home = NSHomeDirectory()
        let path = "\(home)/Documents/private-workspace"

        let output = LogRedactor.redact("workspace=\(path)")

        XCTAssertFalse(output.contains(home))
        XCTAssertTrue(output.contains("workspace=~/Documents/private-workspace"))
        XCTAssertEqual(LogRedactor.redactPath(path), "~/Documents/private-workspace")
    }

    func testRedactsAbsolutePathOutsideHome() {
        XCTAssertEqual(
            LogRedactor.redactPath("/Volumes/PrivateDisk/workspace"),
            "<redacted-path>"
        )
    }

    func testRedactsAPIKeyAndBearerToken() {
        let input = "apiKey=sk-secret123 Authorization: Bearer abc.def token=raw"
        let output = LogRedactor.redact(input)
        XCTAssertFalse(output.contains("sk-secret123"))
        XCTAssertFalse(output.contains("abc.def"))
        XCTAssertFalse(output.contains("raw"))
        XCTAssertTrue(output.contains("<redacted>"))
    }

    func testRedactsQuotedJSONStyleSecrets() {
        let input = #"{"apiKey":"plain-secret","token":"another-secret"}"#
        let output = LogRedactor.redact(input)

        XCTAssertFalse(output.contains("plain-secret"))
        XCTAssertFalse(output.contains("another-secret"))
        XCTAssertTrue(output.contains("\"apiKey\":\"<redacted>\""))
    }

    func testRedactsHyphenatedSecretTokensCompletely() {
        let input = "raw credential sk-proj-abc123-def456"
        let output = LogRedactor.redact(input)

        XCTAssertFalse(output.contains("sk-proj-abc123-def456"))
        XCTAssertFalse(output.contains("abc123-def456"))
        XCTAssertTrue(output.contains("<redacted>"))
    }
}
