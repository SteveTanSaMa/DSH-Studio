//
//  RuntimeVersionOrderingTests.swift
//  DSH Studio
//

import Foundation
import XCTest
@testable import DeepSeekRuntime

/// Verifies Runtime version ordering, including the `-ver<n>` revision suffix.
///
/// These comparisons decide whether an available release is newer than the
/// installation, so an ordering mistake here would either skip a valid update or
/// offer a downgrade.
final class RuntimeVersionOrderingTests: XCTestCase {
    /// A version compares equal to itself.
    func testIdenticalVersionsCompareTheSame() {
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.5-rc.2-ver1", "0.1.5-rc.2-ver1"),
            .orderedSame
        )
    }

    /// The revision suffix compares numerically, so `-ver10` sorts after `-ver9`.
    ///
    /// A lexical comparison would place `-ver10` before `-ver9` and stall updates.
    func testRevisionSuffixComparesNumerically() {
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.5-rc.2-ver9", "0.1.5-rc.2-ver10"),
            .orderedAscending
        )
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.5-rc.2-ver10", "0.1.5-rc.2-ver9"),
            .orderedDescending
        )
    }

    /// The Harness version decides before the revision does.
    func testHarnessVersionDecidesBeforeRevision() {
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.5-rc.2-ver9", "0.1.6-alpha.2-ver1"),
            .orderedAscending
        )
    }

    /// A released Harness version sorts after its own prerelease.
    func testReleaseSortsAfterItsPrerelease() {
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.5-ver1", "0.1.5-rc.2-ver1"),
            .orderedDescending
        )
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.5-rc.2-ver1", "0.1.5-ver1"),
            .orderedAscending
        )
    }

    /// Prerelease identifiers compare numerically before lexically.
    func testPrereleaseIdentifiersCompareNumerically() {
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.5-rc.9-ver1", "0.1.5-rc.10-ver1"),
            .orderedAscending
        )
    }

    /// A recognized Runtime version outranks a string that is not one.
    func testStandardizedVersionOutranksPlainString() {
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.5-rc.2-ver1", "nightly"),
            .orderedDescending
        )
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("nightly", "0.1.5-rc.2-ver1"),
            .orderedAscending
        )
    }

    /// `-ver0` is not an accepted revision, so the string stays a plain version.
    func testZeroRevisionIsNotAStandardizedVersion() {
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.5-ver0", "0.1.5-rc.2-ver1"),
            .orderedAscending
        )
    }

    /// Plain versions compare component by component, numerically when possible.
    func testPlainVersionsCompareNumericallyPerComponent() {
        XCTAssertEqual(RuntimeVersionOrdering.compare("24.9.0", "24.10.0"), .orderedAscending)
        XCTAssertEqual(RuntimeVersionOrdering.compare("1.2.3", "1.2.3"), .orderedSame)
    }
}
