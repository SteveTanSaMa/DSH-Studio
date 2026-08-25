//
//  HarnessProfileStoreTests.swift
//  DSH Studio
//

import Foundation
import XCTest

@testable import DeepSeekRuntime

final class HarnessProfileStoreTests: XCTestCase {
    private var root: URL!
    private var dshHome: URL!
    private var support: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSHStudio.HarnessProfileStoreTests-\(UUID().uuidString)", isDirectory: true)
        dshHome = root.appendingPathComponent("DSH_HOME", isDirectory: true)
        support = root.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testVirtualWebProfileIsSelectableAndCustomProfileIsCreatedAtomically() throws {
        let store = HarnessProfileStore(dshHome: dshHome, supportDirectory: support)

        XCTAssertEqual(store.profile(named: "web")?.selectable, true)
        let created = try store.create(name: "review")

        XCTAssertTrue(created.exists)
        XCTAssertTrue(created.selectable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.directory.appendingPathComponent("package.json").path))
        let manifestData = try Data(contentsOf: created.directory.appendingPathComponent("package.json"))
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        XCTAssertEqual(manifest["name"] as? String, "dsh-profile-review")
        XCTAssertFalse(store.profiles().contains { $0.name.contains("creating-") })
    }

    func testSelectionUsesPendingStateThenPromotesHealthyProfile() throws {
        let store = HarnessProfileStore(dshHome: dshHome, supportDirectory: support)
        _ = try store.create(name: "review")

        try store.select(name: "review")
        XCTAssertEqual(store.selection().pending, "review")
        XCTAssertEqual(store.startupProfile().active, "review")

        try store.markHealthy(name: "review")
        let selection = store.selection()
        XCTAssertEqual(selection.active, "review")
        XCTAssertNil(selection.pending)
        XCTAssertEqual(selection.lastKnownGood, "review")
    }

    func testInvalidProfileRollsBackAndActiveProfileCannotBeDeleted() throws {
        let store = HarnessProfileStore(dshHome: dshHome, supportDirectory: support)
        _ = try store.create(name: "review")
        try store.select(name: "review")
        try store.markHealthy(name: "review")

        XCTAssertThrowsError(try store.create(name: "bad/name")) { error in
            XCTAssertEqual(error as? HarnessProfileStoreError, .invalidName)
        }
        XCTAssertThrowsError(try store.create(name: ".hidden")) { error in
            XCTAssertEqual(error as? HarnessProfileStoreError, .invalidName)
        }
        XCTAssertThrowsError(try store.delete(name: "review")) { error in
            XCTAssertEqual(error as? HarnessProfileStoreError, .cannotDeleteActive)
        }

        let fallback = try store.rollbackToLastKnownGood()
        XCTAssertEqual(fallback, "review")
        XCTAssertEqual(store.selection().active, "review")
    }

    func testMalformedManifestIsNotSelectable() throws {
        let directory = dshHome.appendingPathComponent("profiles/broken", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: directory.appendingPathComponent("package.json"))

        let store = HarnessProfileStore(dshHome: dshHome, supportDirectory: support)
        let broken = try XCTUnwrap(store.profile(named: "broken"))
        XCTAssertFalse(broken.selectable)
        XCTAssertNotNil(broken.problem)
        XCTAssertThrowsError(try store.select(name: "broken"))
    }

    func testSymlinkedProfileIsNotAdmitted() throws {
        let profiles = dshHome.appendingPathComponent("profiles", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(#"{"dsh":{"profile":{"bundles":["@deepseek-ai/dsh-base","@deepseek-ai/dsh-web-app"]}}}"#.utf8)
            .write(to: outside.appendingPathComponent("package.json"))
        try FileManager.default.createSymbolicLink(
            at: profiles.appendingPathComponent("escape", isDirectory: true),
            withDestinationURL: outside
        )

        let store = HarnessProfileStore(dshHome: dshHome, supportDirectory: support)

        XCTAssertNil(store.profile(named: "escape"))
        XCTAssertFalse(store.profiles().contains { $0.name == "escape" })
        XCTAssertThrowsError(try store.delete(name: "escape")) { error in
            XCTAssertEqual(error as? HarnessProfileStoreError, .notFound)
        }
    }
}
