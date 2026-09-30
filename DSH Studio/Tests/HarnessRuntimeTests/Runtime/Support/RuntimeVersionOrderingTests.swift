//
//  RuntimeVersionOrderingTests.swift
//  DSH Studio
//

import Foundation
import XCTest
@testable import DeepSeekRuntime

/// Verifies Runtime version ordering.
///
/// A Runtime version is the Harness version it contains, so these comparisons are
/// semantic-version comparisons — and they decide whether an available release is
/// newer than the installation, so an ordering mistake here would either skip a
/// valid update or offer a downgrade. The Runtime repository's
/// `check-catalog-precedent.sh` reads the same ordering before it publishes.
final class RuntimeVersionOrderingTests: XCTestCase {
    /// A version compares equal to itself.
    func testIdenticalVersionsCompareTheSame() {
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.5-rc.2", "0.1.5-rc.2"),
            .orderedSame
        )
    }

    /// The Harness line decides before anything else.
    func testHarnessLineDecidesFirst() {
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.5-rc.9", "0.1.6-alpha.2"),
            .orderedAscending
        )
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.6-alpha.2", "0.1.5-rc.9"),
            .orderedDescending
        )
    }

    /// A released Harness version sorts after its own prerelease.
    func testReleaseSortsAfterItsPrerelease() {
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.5", "0.1.5-rc.2"),
            .orderedDescending
        )
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.5-rc.2", "0.1.5"),
            .orderedAscending
        )
    }

    /// A recognized Runtime version outranks a string that is not one.
    func testStandardizedVersionOutranksPlainString() {
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.5-rc.2", "nightly"),
            .orderedDescending
        )
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("nightly", "0.1.5-rc.2"),
            .orderedAscending
        )
    }

    /// The retired `-ver<n>` build counter carries no meaning.
    ///
    /// It was this repository's build counter, never an upstream Harness version, and
    /// every release named that way has been unpublished. A string carrying it is read
    /// as an ordinary version, so ordering still follows the Harness line first.
    func testRetiredBuildCounterCarriesNoMeaning() {
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.5-rc.2-ver1", "0.1.6-rc.1"),
            .orderedAscending
        )
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.6-rc.1", "0.1.5-rc.2-ver1"),
            .orderedDescending
        )
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.5-rc.2-ver1", "0.1.5-rc.2-ver1"),
            .orderedSame
        )
    }

    /// Versions order by the semver rules, not by string comparison.
    func testBareVersionsOrderByPrereleaseRules() {
        XCTAssertEqual(RuntimeVersionOrdering.compare("0.1.5-rc.9", "0.1.5-rc.10"), .orderedAscending)
        XCTAssertEqual(RuntimeVersionOrdering.compare("0.1.5-rc.10", "0.1.5-rc.9"), .orderedDescending)
        XCTAssertEqual(RuntimeVersionOrdering.compare("0.1.5-rc.2", "0.1.5"), .orderedAscending)
        XCTAssertEqual(RuntimeVersionOrdering.compare("0.1.5", "0.1.5-rc.2"), .orderedDescending)
        XCTAssertEqual(RuntimeVersionOrdering.compare("0.1.10", "0.2.0"), .orderedAscending)
        XCTAssertEqual(RuntimeVersionOrdering.compare("0.1.5", "0.1.5"), .orderedSame)
    }

    /// Plain versions compare component by component, numerically when possible.
    func testPlainVersionsCompareNumericallyPerComponent() {
        XCTAssertEqual(RuntimeVersionOrdering.compare("24.9.0", "24.10.0"), .orderedAscending)
        XCTAssertEqual(RuntimeVersionOrdering.compare("1.2.3", "1.2.3"), .orderedSame)
    }

    /// Identifiers compare by code point, never by the user's locale.
    ///
    /// The Runtime publication pipeline replicates this ordering to decide which
    /// release may replace the published catalog, so the client must not answer
    /// differently from the pipeline — or from another Mac — for the same two versions.
    /// A locale-aware comparison folds case and is numeric-aware, which would order
    /// (or equate) these pairs the other way round.
    func testPrereleaseIdentifiersCompareByCodePoint() {
        // Case folding would make two different Harness versions compare the same.
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.5-Beta.1", "0.1.5-beta.1"),
            .orderedAscending
        )
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.5-beta.1", "0.1.5-Beta.1"),
            .orderedDescending
        )
        // Numeric-aware collation would read the digits inside the identifier.
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.5-v10", "0.1.5-v9"),
            .orderedAscending
        )
    }

    /// Plain versions keep the same code-point rule outside the standard grammar.
    func testPlainVersionIdentifiersCompareByCodePoint() {
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.5-Beta.1", "0.1.5-beta.1"),
            .orderedAscending
        )
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.5-beta.1", "0.1.5-beta.1"),
            .orderedSame
        )
    }

    /// A numeric identifier ranks below an alphanumeric one, as semver requires.
    func testNumericIdentifierRanksBelowAlphanumeric() {
        XCTAssertEqual(
            RuntimeVersionOrdering.compare("0.1.5-1", "0.1.5-alpha"),
            .orderedAscending
        )
    }
}
