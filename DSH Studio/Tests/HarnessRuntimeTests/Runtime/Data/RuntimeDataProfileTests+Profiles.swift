import Foundation
import XCTest

@testable import DeepSeekRuntime

/// Profile cases: identity, isolation, and what an unreadable state means.
extension RuntimeDataProfileTests {
    /// A legacy profile keeps a stable identity and never moves existing data.
    func testLegacyProfileIsStableAndDoesNotMoveExistingData() throws {
        let support = temporaryRoot.appendingPathComponent("support", isDirectory: true)
        let legacyHome = temporaryRoot.appendingPathComponent("existing-dsh-home", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyHome, withIntermediateDirectories: true)
        let marker = legacyHome.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)

        let store = RuntimeDataProfileStore(supportDirectory: support)
        let first = try store.ensureLegacyProfile(homeURL: legacyHome)
        let second = try store.ensureLegacyProfile(homeURL: legacyHome)

        XCTAssertEqual(first, second)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
        XCTAssertEqual(store.profiles(), [first])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.homeURL.path))
    }

    /// A new profile gets its own isolated data home.
    func testNewProfileUsesAnIsolatedDataHome() throws {
        let store = RuntimeDataProfileStore(supportDirectory: temporaryRoot)
        let legacyHome = temporaryRoot.appendingPathComponent("legacy", isDirectory: true)
        let legacy = try store.ensureLegacyProfile(homeURL: legacyHome, dataFormatID: "sqlite-v1")

        let fresh = try store.createProfile(name: "Harness rc8", dataFormatID: "sqlite-v2")

        XCTAssertNotEqual(fresh.id, legacy.id)
        XCTAssertNotEqual(fresh.homeURL.standardizedFileURL, legacy.homeURL.standardizedFileURL)
        XCTAssertEqual(fresh.dataFormatID, "sqlite-v2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.homeURL.path))
        XCTAssertEqual(store.profiles().count, 2)
    }

    /// A malformed active-state file is ignored rather than partially trusted.
    func testMalformedActiveStateIsIgnored() throws {
        let store = RuntimeDataProfileStore(supportDirectory: temporaryRoot)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":999,"profileID":"bad","runtimeVersion":""}"#.utf8)
            .write(to: store.activeStateURL)

        XCTAssertNil(store.activeState())
        XCTAssertNil(store.activeProfile())
    }

    /// Profile identifiers containing path components are rejected.
    func testProfileIdentifiersRejectPathComponents() {
        XCTAssertFalse(RuntimeDataProfileStore.isSafeIdentifier("."))
        XCTAssertFalse(RuntimeDataProfileStore.isSafeIdentifier(".."))
    }

    /// An existing unknown profile is not upgraded by what the Runtime declares.
    func testExistingUnknownProfileIsNotUpgradedByRuntimeDeclaration() throws {
        let store = RuntimeDataProfileStore(supportDirectory: temporaryRoot)
        let home = temporaryRoot.appendingPathComponent("legacy-data", isDirectory: true)
        let first = try store.ensureLegacyProfile(homeURL: home)
        let second = try store.ensureLegacyProfile(homeURL: home, dataFormatID: "sqlite-v2")

        XCTAssertEqual(first, second)
        XCTAssertNil(second.dataFormatID)
    }
}
