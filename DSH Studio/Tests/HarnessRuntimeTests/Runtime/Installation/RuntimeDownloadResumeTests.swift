//
//  RuntimeDownloadResumeTests.swift
//  DSH Studio
//

import XCTest
@testable import DeepSeekRuntime

/// Guards the rule that decides whether a partial download can be continued.
///
/// The rule is deliberately small and total: it is the only place that decides whether the
/// bytes already on disk are treated as a prefix of the artifact, and the checksum the
/// caller performs afterwards is what decides whether they are the right bytes.
final class RuntimeDownloadResumeTests: XCTestCase {

    /// A partial file continued by a ranged answer is appended to.
    func testAPartialResponseContinuesThePartialFile() {
        XCTAssertEqual(RuntimeDownloadResume.outcome(partialBytes: 1024, statusCode: 206), .append)
    }

    /// A server that ignores the range replaces the partial file.
    func testAFullResponseReplacesThePartialFile() {
        XCTAssertEqual(RuntimeDownloadResume.outcome(partialBytes: 1024, statusCode: 200), .replace)
    }

    /// A first attempt has nothing to continue.
    func testAFirstAttemptStartsFromZero() {
        XCTAssertEqual(RuntimeDownloadResume.outcome(partialBytes: 0, statusCode: 200), .replace)
        XCTAssertEqual(RuntimeDownloadResume.outcome(partialBytes: 0, statusCode: 206), .replace)
    }

    /// Anything else means the partial cannot be trusted as a prefix.
    func testUnexpectedStatusesCannotBeContinued() {
        for status in [301, 403, 404, 416, 500, 503] {
            XCTAssertNil(
                RuntimeDownloadResume.outcome(partialBytes: 1024, statusCode: status),
                "HTTP \(status) must not continue a partial file"
            )
        }
    }

    /// The range header is only sent when there is something to continue.
    func testTheRangeHeaderNamesTheMissingTail() {
        XCTAssertEqual(RuntimeDownloadResume.rangeHeader(partialBytes: 4096), "bytes=4096-")
        XCTAssertNil(RuntimeDownloadResume.rangeHeader(partialBytes: 0))
    }
}
