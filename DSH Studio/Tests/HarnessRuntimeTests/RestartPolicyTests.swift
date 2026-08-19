//
//  RestartPolicyTests.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import XCTest
@testable import DeepSeekRuntime

/// Verifies bounded exponential-style restart attempts.
final class RestartPolicyTests: XCTestCase {
    func testDelaysAreBoundedAndStopAfterMax() {
        let policy = RestartPolicy(maxAttempts: 3, delays: [1, 2, 4])
        XCTAssertEqual(policy.delay(forAttempt: 1), 1)
        XCTAssertEqual(policy.delay(forAttempt: 2), 2)
        XCTAssertEqual(policy.delay(forAttempt: 3), 4)
        XCTAssertNil(policy.delay(forAttempt: 4))
    }

    func testMaxAttemptsIsAppliedEvenWhenMoreDelaysAreProvided() {
        let policy = RestartPolicy(maxAttempts: 1, delays: [1, 2, 4])

        XCTAssertEqual(policy.delay(forAttempt: 1), 1)
        XCTAssertNil(policy.delay(forAttempt: 2))
    }
}
