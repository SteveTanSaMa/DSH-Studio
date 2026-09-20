//
//  RestartTrackerTests.swift
//  DSH Studio
//

import XCTest
@testable import DeepSeekRuntime

/// Verifies the crash budget the restart policy is applied against.
///
/// The tracker is what stops an endless crash loop, so an off-by-one here would
/// either restart forever or give up one attempt early.
final class RestartTrackerTests: XCTestCase {
    /// A fresh tracker has recorded nothing.
    func testStartsEmpty() {
        let tracker = RestartTracker()
        XCTAssertEqual(tracker.attempts, 0)
        XCTAssertNil(tracker.lastCrashDate)
    }

    /// Each crash counts up and reports its own one-based number.
    func testRecordCrashCountsUp() throws {
        let tracker = RestartTracker()
        XCTAssertEqual(tracker.recordCrash(), 1)
        XCTAssertEqual(tracker.recordCrash(), 2)
        XCTAssertEqual(tracker.attempts, 2)
        XCTAssertNotNil(try XCTUnwrap(tracker.lastCrashDate))
    }

    /// Resetting clears both the budget and the recorded time.
    func testResetClearsBudgetAndTime() {
        let tracker = RestartTracker()
        _ = tracker.recordCrash()
        tracker.reset()
        XCTAssertEqual(tracker.attempts, 0)
        XCTAssertNil(tracker.lastCrashDate)
    }

    /// The recorded time follows the most recent crash.
    func testCrashTimeFollowsTheLatestCrash() throws {
        let tracker = RestartTracker()
        _ = tracker.recordCrash()
        let first = try XCTUnwrap(tracker.lastCrashDate)
        _ = tracker.recordCrash()
        let second = try XCTUnwrap(tracker.lastCrashDate)
        XCTAssertGreaterThanOrEqual(second, first)
    }
}
