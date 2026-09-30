//
//  HarnessProfileStoreTests.swift
//  DSH Studio
//

import Foundation
import XCTest

@testable import DeepSeekRuntime

/// Guards profile creation, selection, and the persisted state around them.
final class HarnessProfileStoreTests: XCTestCase {
    private var root: URL!
    private var dshHome: URL!
    private var support: URL!

    /// Creates an isolated support root and data home for each test.
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSHStudio.HarnessProfileStoreTests-\(UUID().uuidString)", isDirectory: true)
        dshHome = root.appendingPathComponent("DSH_HOME", isDirectory: true)
        support = root.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Removes the isolated root; a missing root is ignored.
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The virtual web profile is selectable but never written as a directory.
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

    /// Selection is recorded as pending and only promoted after a healthy start.
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

    /// An invalid selection rolls back, and the active profile cannot be deleted.
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

    /// A profile with an unreadable manifest is not offered for selection.
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

    /// A symlinked profile directory is rejected, so a link cannot redirect the store.
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

    /// Search, recent order, and status persist independently of each other.
    func testProfileSearchRecentOrderAndStatusArePersistedSeparately() throws {
        let store = HarnessProfileStore(dshHome: dshHome, supportDirectory: support)
        _ = try store.create(name: "review")
        _ = try store.create(name: "research")

        XCTAssertEqual(store.search(query: "REV").map(\.name), ["review"])
        XCTAssertEqual(store.status(for: "web"), .active)

        try store.select(name: "research")
        XCTAssertEqual(store.status(for: "research"), .pending)
        XCTAssertEqual(store.recentProfiles(limit: 2).map(\.name), ["research", "review"])

        try store.markHealthy(name: "research")
        XCTAssertEqual(store.status(for: "research"), .active)
        XCTAssertEqual(store.recentProfiles(limit: 2).map(\.name), ["research", "review"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.recentStateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.selectionStateURL.path))
        XCTAssertNotEqual(store.recentStateURL, store.selectionStateURL)
    }

    /// Two data homes keep separate selection and recent state.
    func testSelectionAndRecentStateAreIsolatedPerDataHome() throws {
        let firstHome = root.appendingPathComponent("first-home", isDirectory: true)
        let secondHome = root.appendingPathComponent("second-home", isDirectory: true)
        let firstStore = HarnessProfileStore(dshHome: firstHome, supportDirectory: support)
        let secondStore = HarnessProfileStore(dshHome: secondHome, supportDirectory: support)

        _ = try firstStore.create(name: "review")
        _ = try secondStore.create(name: "research")
        try firstStore.select(name: "review")
        try firstStore.markHealthy(name: "review")
        try secondStore.select(name: "research")
        _ = secondStore.startupProfile()

        XCTAssertEqual(firstStore.selection().active, "review")
        XCTAssertEqual(secondStore.selection().active, "research")
        XCTAssertTrue(firstStore.isRecentlyUsed(name: "review"))
        XCTAssertFalse(firstStore.isRecentlyUsed(name: "research"))
        XCTAssertTrue(secondStore.isRecentlyUsed(name: "research"))
        XCTAssertFalse(secondStore.isRecentlyUsed(name: "review"))
        XCTAssertNotEqual(firstStore.selectionStateURL, secondStore.selectionStateURL)
        XCTAssertNotEqual(firstStore.recentStateURL, secondStore.recentStateURL)
    }

    /// A successful install vendors the runtime packages and registers the bundle.
    func testSettingsInstallRegistersBundleAndVendorsRuntimePackages() throws {
        let store = HarnessProfileStore(dshHome: dshHome, supportDirectory: support)
        let source = try makeSettingsPluginSource()

        try store.installStudioSettingsPlugin(
            from: source,
            runtimeNodeModules: try makeRuntimeNodeModules()
        )

        let profile = dshHome
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(HarnessProfileStore.defaultProfileName, isDirectory: true)
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: profile.appendingPathComponent("package.json"))
            ) as? [String: Any]
        )
        let profileConfig = (manifest["dsh"] as? [String: Any])?["profile"] as? [String: Any]
        XCTAssertEqual(
            profileConfig?["bundles"] as? [String],
            [
                HarnessProfileStore.baseBundle,
                HarnessProfileStore.webBundle,
                HarnessProfileStore.studioSettingsBundle
            ]
        )
        let installed = profile
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(HarnessProfileStore.studioSettingsBundle, isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: installed.appendingPathComponent("lib/client.js").path
            )
        )
        for package in ["@deepseek-ai/schemastery", "@deepseek-ai/cosmokit", "@standard-schema/spec"] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: installed.appendingPathComponent("node_modules/\(package)").path
                ),
                "\(package) must be vendored out of the Runtime"
            )
        }
        let leftovers = try FileManager.default
            .contentsOfDirectory(
                atPath: profile.appendingPathComponent("node_modules").path
            )
            .filter { $0.hasPrefix(".") }
        XCTAssertTrue(leftovers.isEmpty, "no staging or backup directories remain: \(leftovers)")
    }

    /// A missing runtime package is reported once, not wrapped in itself.
    ///
    /// The app log used to read `Profile 保存失败：Profile 保存失败：Runtime 缺少 …`,
    /// which hid what was actually missing.
    func testSettingsInstallReportsMissingRuntimePackageOnce() throws {
        let store = HarnessProfileStore(dshHome: dshHome, supportDirectory: support)
        let source = try makeSettingsPluginSource()
        let runtimeNodeModules = root
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtimeNodeModules,
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(
            try store.installStudioSettingsPlugin(
                from: source,
                runtimeNodeModules: runtimeNodeModules
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Profile 保存失败：Runtime 缺少 @deepseek-ai/schemastery"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: dshHome.appendingPathComponent("profiles/web/package.json").path
            ),
            "a failed install leaves no profile behind"
        )
    }

    /// Creates a plugin source directory shaped like the bundled settings page.
    ///
    /// - Returns: Directory holding a manifest and one file under `lib`.
    /// - Throws: When the fixture cannot be written.
    private func makeSettingsPluginSource() throws -> URL {
        let source = root.appendingPathComponent("dsh-studio-settings", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("lib", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(#"{"name":"dsh-studio-settings","version":"1.0.0"}"#.utf8).write(
            to: source.appendingPathComponent("package.json")
        )
        try Data("export {}\n".utf8).write(
            to: source.appendingPathComponent("lib/client.js")
        )
        return source
    }

    /// Creates a runtime dependency tree holding the packages the page vendors.
    ///
    /// - Returns: A `node_modules` directory with the three vendored packages.
    /// - Throws: When the fixture cannot be written.
    private func makeRuntimeNodeModules() throws -> URL {
        let nodeModules = root
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("node_modules", isDirectory: true)
        for package in ["@deepseek-ai/schemastery", "@deepseek-ai/cosmokit", "@standard-schema/spec"] {
            let directory = nodeModules.appendingPathComponent(package, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Data(#"{"name":"\#(package)"}"#.utf8).write(
                to: directory.appendingPathComponent("package.json")
            )
        }
        return nodeModules
    }
}
