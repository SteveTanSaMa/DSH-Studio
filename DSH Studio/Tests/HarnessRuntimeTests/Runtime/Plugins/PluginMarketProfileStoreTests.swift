import Foundation
import XCTest
@testable import DeepSeekRuntime

final class PluginMarketProfileStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSHStudio-PluginMarket-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testEmptyProfileAndInsertOnlyPatchAreValid() throws {
        let store = makeStore()
        XCTAssertNil(try store.inspect().dependencySpec)
        XCTAssertTrue(try store.isMarketEnabled())

        try store.ensureProfileDirectory()
        try write(
            "- insert:\n    - id: another-plugin\n      name: another-plugin\n",
            relativePath: "cordis.patch.yml"
        )
        XCTAssertTrue(try store.isMarketEnabled())

        try store.setMarketEnabled(false)
        let patch = try read(relativePath: "cordis.patch.yml")
        XCTAssertTrue(patch.contains("- id: another-plugin"))
        XCTAssertTrue(patch.contains("- id: dsh-market"))
        XCTAssertTrue(patch.contains("  disabled: true"))
        XCTAssertFalse(try store.isMarketEnabled())
    }

    func testCommentedEmptyPatchIsValid() throws {
        let store = makeStore()
        try store.ensureProfileDirectory()
        try write(
            """
            # Your patch layer for this dsh profile:
            # a top-level YAML array of loader patch entries.
            []
            """,
            relativePath: "cordis.patch.yml"
        )

        XCTAssertTrue(try store.isMarketEnabled())
    }

    func testTogglePreservesIndentationAndComments() throws {
        let store = makeStore()
        try store.ensureProfileDirectory()
        try write(
            "- id: dsh-market\n  name: dshmarket\n  disabled: false # user choice\n",
            relativePath: "cordis.patch.yml"
        )

        try store.setMarketEnabled(false)
        let patch = try read(relativePath: "cordis.patch.yml")
        XCTAssertTrue(patch.contains("  disabled: true # user choice"))
        XCTAssertFalse(patch.contains("\ndisabled: true"))
        XCTAssertFalse(try store.isMarketEnabled())
    }

    func testExpectedInstallationRequiresExactVersionAndIntegrity() throws {
        let store = makeStore()
        try writeFixture(store: store)

        let inspection = try store.validateExpectedInstallation()
        XCTAssertEqual(inspection.dependencySpec, PluginMarketRelease.packageVersion)
        XCTAssertEqual(inspection.installedVersion, PluginMarketRelease.packageVersion)
        XCTAssertTrue(inspection.bundleListed)
        XCTAssertTrue(inspection.bundlePatchValid)
        XCTAssertTrue(inspection.entryPointValid)
        XCTAssertTrue(inspection.lockIntegrityValid)

        try write(
            "{\"dependencies\":{\"dshmarket\":\"^\(PluginMarketRelease.packageVersion)\"}}",
            relativePath: "package.json"
        )
        XCTAssertThrowsError(try store.validateExpectedInstallation())
    }

    func testSnapshotRestoresPackageMaterializationAndMarketState() throws {
        let store = makeStore()
        try writeFixture(store: store)
        try write("{\"phase\":\"before\"}", relativePath: ".dsh-market/state.json")
        let snapshot = try store.snapshot()

        try write("changed", relativePath: "node_modules/dshmarket/lib/index.js")
        try write("{\"phase\":\"after\"}", relativePath: ".dsh-market/state.json")
        try store.restore(snapshot)

        XCTAssertEqual(
            try read(relativePath: "node_modules/dshmarket/lib/index.js"),
            "// bundled entry"
        )
        XCTAssertEqual(
            try read(relativePath: ".dsh-market/state.json"),
            "{\"phase\":\"before\"}"
        )
        XCTAssertTrue(try store.validateExpectedInstallation().entryPointValid)
    }

    func testPnpmInternalPackageSymlinkIsAllowedAndRestored() throws {
        let store = makeStore()
        try store.ensureProfileDirectory()
        let packageRoot = store.profileDirectory
            .appendingPathComponent("node_modules/.pnpm/dshmarket@\(PluginMarketRelease.packageVersion)/node_modules/dshmarket", isDirectory: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        try write(
            "{\"dependencies\":{\"dshmarket\":\"\(PluginMarketRelease.packageVersion)\"},\"dsh\":{\"profile\":{\"bundles\":[\"dshmarket\"]}}}",
            relativePath: "package.json"
        )
        try write(
            "{\"name\":\"dshmarket\",\"version\":\"\(PluginMarketRelease.packageVersion)\",\"main\":\"lib/index.js\",\"dsh\":{\"bundle\":{\"patch\":\"./cordis.patch.yml\"}}}",
            relativePath: "node_modules/.pnpm/dshmarket@\(PluginMarketRelease.packageVersion)/node_modules/dshmarket/package.json"
        )
        try write(
            "// bundled entry",
            relativePath: "node_modules/.pnpm/dshmarket@\(PluginMarketRelease.packageVersion)/node_modules/dshmarket/lib/index.js"
        )
        try write(
            "# dsh bundle patch: inserts this plugin into a profile's layer stack.\n- insert:\n    - id: dsh-market\n      name: 'dshmarket'\n",
            relativePath: "node_modules/.pnpm/dshmarket@\(PluginMarketRelease.packageVersion)/node_modules/dshmarket/cordis.patch.yml"
        )
        try write(
            "lockfileVersion: '9.0'\npackages:\n  dshmarket@\(PluginMarketRelease.packageVersion):\n    resolution: {}\n    integrity: \(PluginMarketRelease.packageIntegrity)\n",
            relativePath: "pnpm-lock.yaml"
        )
        let directPackage = store.profileDirectory.appendingPathComponent("node_modules/dshmarket", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            atPath: directPackage.path,
            withDestinationPath: ".pnpm/dshmarket@\(PluginMarketRelease.packageVersion)/node_modules/dshmarket"
        )

        XCTAssertTrue(try store.validateExpectedInstallation().entryPointValid)
        let snapshot = try store.snapshot()
        try Data("changed".utf8).write(to: packageRoot.appendingPathComponent("lib/index.js"))
        try store.restore(snapshot)

        XCTAssertTrue(FileManager.default.fileExists(atPath: directPackage.path))
        XCTAssertEqual(
            try String(contentsOf: directPackage.appendingPathComponent("lib/index.js"), encoding: .utf8),
            "// bundled entry"
        )
    }

    func testNestedPackageSymlinkIsRejected() throws {
        let store = makeStore()
        try store.ensureProfileDirectory()
        try write(
            "{\"dependencies\":{\"dshmarket\":\"\(PluginMarketRelease.packageVersion)\"}}",
            relativePath: "package.json"
        )
        let nodeModules = store.profileDirectory.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        let outside = temporaryDirectory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: nodeModules.appendingPathComponent(PluginMarketRelease.packageName, isDirectory: true),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try store.inspect()) { error in
            guard case PluginMarketManagerError.unsafeProfile = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testMarketCanBeRemovedWithoutDroppingOtherPatchRows() throws {
        let store = makeStore()
        try store.ensureProfileDirectory()
        try write(
            "- id: other\n  disabled: true\n- id: dsh-market\n  disabled: false\n",
            relativePath: "cordis.patch.yml"
        )

        try store.removeMarketEntry()
        let patch = try read(relativePath: "cordis.patch.yml")
        XCTAssertTrue(patch.contains("- id: other"))
        XCTAssertFalse(patch.contains("dsh-market"))
    }

    func testCanonicalNestedMarketPatchCanBeRemovedCompletely() throws {
        let store = makeStore()
        try store.ensureProfileDirectory()
        try write(
            "- insert:\n    - id: dsh-market\n      name: dshmarket\n",
            relativePath: "cordis.patch.yml"
        )

        try store.removeMarketEntry()

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.profileDirectory.appendingPathComponent("cordis.patch.yml").path
            )
        )
    }

    func testAbsentValidationRejectsResidualBundleAndPnpmMaterialization() throws {
        let store = makeStore()
        try store.ensureProfileDirectory()
        try write(
            "{\"dsh\":{\"profile\":{\"bundles\":[\"dshmarket\"]}}}",
            relativePath: "package.json"
        )
        let packageRoot = store.profileDirectory
            .appendingPathComponent("node_modules/.pnpm/dshmarket@(PluginMarketRelease.packageVersion)", isDirectory: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.validateMarketAbsent())
    }

    func testRestoreRemovesResidualPnpmMaterialization() throws {
        let store = makeStore()
        try store.ensureProfileDirectory()
        let snapshot = try store.snapshot()
        let packageRoot = store.profileDirectory
            .appendingPathComponent("node_modules/.pnpm/dshmarket@(PluginMarketRelease.packageVersion)", isDirectory: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        try store.restore(snapshot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: packageRoot.path))
    }

    private func makeStore() -> PluginMarketProfileStore {
        PluginMarketProfileStore(dshHome: temporaryDirectory.appendingPathComponent("DSH_HOME", isDirectory: true))
    }

    private func writeFixture(store: PluginMarketProfileStore) throws {
        try store.ensureProfileDirectory()
        try write(
            "{\"dependencies\":{\"dshmarket\":\"\(PluginMarketRelease.packageVersion)\"},\"dsh\":{\"profile\":{\"bundles\":[\"dshmarket\"]}}}",
            relativePath: "package.json"
        )
        try write(
            "{\"name\":\"dshmarket\",\"version\":\"\(PluginMarketRelease.packageVersion)\",\"main\":\"lib/index.js\",\"dsh\":{\"bundle\":{\"patch\":\"./cordis.patch.yml\"}}}",
            relativePath: "node_modules/dshmarket/package.json"
        )
        try write(
            "// bundled entry",
            relativePath: "node_modules/dshmarket/lib/index.js"
        )
        try write(
            "# dsh bundle patch: inserts this plugin into a profile's layer stack.\n- insert:\n    - id: dsh-market\n      name: 'dshmarket'\n",
            relativePath: "node_modules/dshmarket/cordis.patch.yml"
        )
        try write(
            "lockfileVersion: '9.0'\npackages:\n  dshmarket@\(PluginMarketRelease.packageVersion):\n    resolution: {}\n    integrity: \(PluginMarketRelease.packageIntegrity)\n",
            relativePath: "pnpm-lock.yaml"
        )
    }

    private func write(_ text: String, relativePath: String) throws {
        let url = temporaryDirectory
            .appendingPathComponent("DSH_HOME", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(PluginMarketRelease.profileName, isDirectory: true)
            .appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(relativePath: String) throws -> String {
        let url = temporaryDirectory
            .appendingPathComponent("DSH_HOME", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(PluginMarketRelease.profileName, isDirectory: true)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
