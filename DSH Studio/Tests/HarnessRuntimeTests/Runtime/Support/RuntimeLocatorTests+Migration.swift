import XCTest
@testable import DeepSeekRuntime

extension RuntimeLocatorTests {

    func testCompleteLegacyRuntimeMovesToVersionedDirectory() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepSeekStudio.RuntimeMigration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let legacyRoot = support.appendingPathComponent("Runtime", isDirectory: true)
        try makeRuntimeFixture(
            root: legacyRoot,
            runtimeVersion: "2026.08.19.1",
            harnessVersion: "0.1.0-rc.7"
        )

        let migrated = RuntimeLocator.migrateLegacyRuntimeIfNeeded(
            supportDirectory: support,
            architecture: "darwin-arm64"
        )
        let expectedRoot = try XCTUnwrap(
            RuntimeLocator.versionedRuntimeRoot(
                supportDirectory: support,
                runtimeVersion: "2026.08.19.1"
            )
        )

        XCTAssertEqual(migrated, expectedRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyRoot.path))
        XCTAssertEqual(
            RuntimeLocator.installationManifest(root: expectedRoot)?.runtimeVersion,
            "2026.08.19.1"
        )
    }

    func testLegacyRuntimeMatchingActiveStateCanBeMigrated() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepSeekStudio.RuntimeMigrationActiveState-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let legacyRoot = support.appendingPathComponent("Runtime", isDirectory: true)
        try makeRuntimeFixture(
            root: legacyRoot,
            runtimeVersion: "2026.08.19.1",
            harnessVersion: "0.1.0-rc.7"
        )
        let activeState = RuntimeActiveState(
            profileID: "legacy-profile",
            runtimeVersion: "2026.08.19.1",
            dataFormatID: "sqlite-v1"
        )
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try JSONEncoder().encode(activeState).write(
            to: support.appendingPathComponent("active-state.json"),
            options: .atomic
        )

        let migrated = RuntimeLocator.migrateLegacyRuntimeIfNeeded(
            supportDirectory: support,
            architecture: "darwin-arm64"
        )

        XCTAssertEqual(
            migrated,
            RuntimeLocator.versionedRuntimeRoot(
                supportDirectory: support,
                runtimeVersion: "2026.08.19.1"
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyRoot.path))
    }

    func testLegacyRuntimeWithDifferentActiveStateIsNotMigrated() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepSeekStudio.RuntimeMigrationActiveStateConflict-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let legacyRoot = support.appendingPathComponent("Runtime", isDirectory: true)
        try makeRuntimeFixture(
            root: legacyRoot,
            runtimeVersion: "2026.08.19.1",
            harnessVersion: "0.1.0-rc.7"
        )
        let activeState = RuntimeActiveState(
            profileID: "legacy-profile",
            runtimeVersion: "2026.08.20.1",
            dataFormatID: "sqlite-v2"
        )
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try JSONEncoder().encode(activeState).write(
            to: support.appendingPathComponent("active-state.json"),
            options: .atomic
        )

        XCTAssertNil(
            RuntimeLocator.migrateLegacyRuntimeIfNeeded(
                supportDirectory: support,
                architecture: "darwin-arm64"
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyRoot.path))
    }

    func testIncompleteLegacyRuntimeIsNotMoved() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepSeekStudio.RuntimeMigrationIncomplete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let legacyRoot = support.appendingPathComponent("Runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        try Data("incomplete".utf8).write(
            to: legacyRoot.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        XCTAssertNil(
            RuntimeLocator.migrateLegacyRuntimeIfNeeded(
                supportDirectory: support,
                architecture: "darwin-arm64"
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyRoot.path))
    }

    func testExistingVersionedRuntimePreventsLegacyOverwrite() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepSeekStudio.RuntimeMigrationConflict-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let legacyRoot = support.appendingPathComponent("Runtime", isDirectory: true)
        let versionedRoot = try XCTUnwrap(
            RuntimeLocator.versionedRuntimeRoot(
                supportDirectory: support,
                runtimeVersion: "2026.08.19.1"
            )
        )
        try makeRuntimeFixture(
            root: legacyRoot,
            runtimeVersion: "2026.08.19.1",
            harnessVersion: "0.1.0-rc.7"
        )
        try makeRuntimeFixture(
            root: versionedRoot,
            runtimeVersion: "2026.08.19.1",
            harnessVersion: "0.1.0-rc.8"
        )

        XCTAssertNil(
            RuntimeLocator.migrateLegacyRuntimeIfNeeded(
                supportDirectory: support,
                architecture: "darwin-arm64"
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyRoot.path))
        XCTAssertEqual(
            RuntimeLocator.installationManifest(root: versionedRoot)?.harnessVersion,
            "0.1.0-rc.8"
        )
    }

    func testLegacyRollbackPairRemainsTogether() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepSeekStudio.RuntimeMigrationRollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let legacyRoot = support.appendingPathComponent("Runtime", isDirectory: true)
        let legacyBackup = RuntimeLocator.rollbackRoot(root: legacyRoot)
        try makeRuntimeFixture(
            root: legacyRoot,
            runtimeVersion: "2026.08.19.1",
            harnessVersion: "0.1.0-rc.7"
        )
        try makeRuntimeFixture(
            root: legacyBackup,
            runtimeVersion: "2026.08.18.1",
            harnessVersion: "0.1.0-rc.6"
        )

        XCTAssertNil(
            RuntimeLocator.migrateLegacyRuntimeIfNeeded(
                supportDirectory: support,
                architecture: "darwin-arm64"
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyBackup.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: support.appendingPathComponent("Runtimes", isDirectory: true).path
            )
        )
    }
}
