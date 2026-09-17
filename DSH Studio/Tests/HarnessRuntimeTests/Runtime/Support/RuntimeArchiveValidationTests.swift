//
//  RuntimeArchiveValidationTests.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import XCTest
@testable import DeepSeekRuntime

/// Verifies the path boundary applied before a Runtime archive is extracted.
final class RuntimeArchiveValidationTests: XCTestCase {
    private let validListing = """
    manifest.json
    node/
    node/darwin-arm64/bin/node
    harness/
    harness/darwin-arm64/0.1.1-rc.2/package.json
    """

    /// A listing produced by the project builder is accepted.
    func testValidBuilderListingIsAccepted() {
        XCTAssertNoThrow(try RuntimeArchiveListingValidator.validate(validListing))
    }

    /// An absolute member path is rejected.
    func testAbsolutePathIsRejected() {
        assertRejected("manifest.json\nnode/\nharness/\n/etc/passwd\n")
    }

    /// A `..` path segment is rejected.
    func testParentTraversalIsRejected() {
        assertRejected("manifest.json\nnode/\nharness/\n../../outside\n")
    }

    /// A backslash in a member path is rejected.
    func testBackslashPathIsRejected() {
        assertRejected("manifest.json\nnode/\nharness/\nnode\\outside\n")
    }

    /// A top-level file outside the allowed roots is rejected.
    func testUnrelatedTopLevelFileIsRejected() {
        assertRejected("manifest.json\nnode/\nharness/\nREADME.md\n")
    }

    /// A listing without the required directories is rejected.
    func testMissingRequiredDirectoryIsRejected() {
        assertRejected("manifest.json\nnode/darwin-arm64/bin/node\n")
    }

    private func assertRejected(_ listing: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(
            try RuntimeArchiveListingValidator.validate(listing),
            file: file,
            line: line
        ) { error in
            guard case .runtimeValidationFailed = error as? RuntimeProvisioningError else {
                XCTFail("expected archive validation failure, got \(error)", file: file, line: line)
                return
            }
        }
    }
}
