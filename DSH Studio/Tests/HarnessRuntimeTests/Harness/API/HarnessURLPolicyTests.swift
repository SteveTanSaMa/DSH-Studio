//
//  HarnessURLPolicyTests.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import XCTest
@testable import DeepSeekHarness

/// Locks down the explicit IPv4 loopback-only transport boundary.
final class HarnessURLPolicyTests: XCTestCase {
    func testOnlyExplicitIPv4LoopbackWithPortIsAllowed() {
        XCTAssertTrue(HarnessURLPolicy.isAllowedLoopback(URL(string: "http://127.0.0.1:43210")!))
        XCTAssertTrue(HarnessURLPolicy.isAllowedLoopback(URL(string: "https://127.0.0.1:43210")!))
        XCTAssertFalse(HarnessURLPolicy.isAllowedLoopback(URL(string: "http://localhost:43210")!))
        XCTAssertFalse(HarnessURLPolicy.isAllowedLoopback(URL(string: "http://0.0.0.0:43210")!))
        XCTAssertFalse(HarnessURLPolicy.isAllowedLoopback(URL(string: "http://[::1]:43210")!))
    }

    func testCredentialsInLoopbackURLAreRejected() {
        XCTAssertFalse(
            HarnessURLPolicy.isAllowedLoopback(
                URL(string: "http://user:password@127.0.0.1:43210")!
            )
        )
    }
}
