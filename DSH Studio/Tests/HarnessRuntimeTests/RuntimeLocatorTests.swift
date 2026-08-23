//
//  RuntimeLocatorTests.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import XCTest
@testable import DeepSeekRuntime

/// Verifies architecture-specific Runtime and Application Support paths.
final class RuntimeLocatorTests: XCTestCase {
    func testArchitectureDirectoryIsDarwinStyle() {
        let arch = RuntimeLocator.architectureDirectory()
        XCTAssertTrue(arch == "darwin-arm64" || arch == "darwin-x64")
    }

    func testNodeExecutablePathUsesArchitectureDirectory() {
        let root = URL(fileURLWithPath: "/tmp/runtime")
        let node = RuntimeLocator.nodeExecutable(root: root, architecture: "darwin-arm64")
        XCTAssertEqual(node.lastPathComponent, "node")
        XCTAssertTrue(node.path.contains("darwin-arm64"))
    }

    func testHarnessEntryUsesArchitectureDirectory() {
        let root = URL(fileURLWithPath: "/tmp/runtime")
        let entry = RuntimeLocator.harnessEntry(root: root, architecture: "darwin-x64")
        XCTAssertTrue(entry.path.contains("harness/darwin-x64/0.1.0-rc.6"))
        XCTAssertTrue(entry.path.hasSuffix("@deepseek-ai/dsh/lib/bin.js"))
    }

    func testVersionedRuntimePathsAreSeparatedByRuntimeVersion() {
        let support = URL(fileURLWithPath: "/tmp/dsh-support", isDirectory: true)

        let oldRoot = RuntimeLocator.versionedRuntimeRoot(
            supportDirectory: support,
            runtimeVersion: "2026.08.20.1"
        )
        let newRoot = RuntimeLocator.versionedRuntimeRoot(
            supportDirectory: support,
            runtimeVersion: "2026.08.21.1"
        )

        XCTAssertNotEqual(oldRoot, newRoot)
        XCTAssertTrue(oldRoot?.path.hasSuffix("Runtimes/2026.08.20.1") == true)
        XCTAssertTrue(
            oldRoot.map { RuntimeLocator.isVersionedRuntimeRoot($0, supportDirectory: support) } == true
        )
        XCTAssertEqual(
            oldRoot.map { RuntimeLocator.candidateRoot(root: $0, runtimeVersion: "2026.08.21.1") },
            newRoot
        )
    }

    func testVersionedRuntimeRejectsPathComponents() {
        XCTAssertNil(
            RuntimeLocator.versionedRuntimeRoot(
                supportDirectory: URL(fileURLWithPath: "/tmp/dsh-support", isDirectory: true),
                runtimeVersion: ".."
            )
        )
        XCTAssertFalse(RuntimeLocator.isSafeRuntimeVersion("."))
        XCTAssertFalse(RuntimeLocator.isSafeRuntimeVersion(".."))
    }

    func testRuntimeRootUsesMatchingLegacyDuringRecovery() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepSeekStudio.RuntimeRootRecovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let legacyRoot = support.appendingPathComponent("Runtime", isDirectory: true)
        try makeRuntimeFixture(
            root: legacyRoot,
            runtimeVersion: "old-runtime",
            harnessVersion: "0.1.0-rc.7"
        )
        let activeState = RuntimeActiveState(
            profileID: "legacy-profile",
            runtimeVersion: "old-runtime",
            dataFormatID: "sqlite-v1"
        )
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try JSONEncoder().encode(activeState).write(
            to: support.appendingPathComponent("active-state.json"),
            options: .atomic
        )

        XCTAssertEqual(
            RuntimeLocator.runtimeRoot(
                fileManager: .default,
                supportDirectory: support
            ),
            legacyRoot
        )
    }

    func testRuntimeRootDoesNotUseUnrelatedLegacyWhenActiveTargetIsMissing() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepSeekStudio.RuntimeRootConflict-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let legacyRoot = support.appendingPathComponent("Runtime", isDirectory: true)
        try makeRuntimeFixture(
            root: legacyRoot,
            runtimeVersion: "old-runtime",
            harnessVersion: "0.1.0-rc.7"
        )
        let activeRoot = try XCTUnwrap(
            RuntimeLocator.versionedRuntimeRoot(
                supportDirectory: support,
                runtimeVersion: "new-runtime"
            )
        )
        let activeState = RuntimeActiveState(
            profileID: "legacy-profile",
            runtimeVersion: "new-runtime",
            dataFormatID: "sqlite-v2"
        )
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try JSONEncoder().encode(activeState).write(
            to: support.appendingPathComponent("active-state.json"),
            options: .atomic
        )

        XCTAssertEqual(
            RuntimeLocator.runtimeRoot(
                fileManager: .default,
                supportDirectory: support
            ),
            activeRoot
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyRoot.path))
    }

    func testApplicationSupportUsesDSHStudioNamespace() {
        let support = RuntimeLocator.applicationSupportDirectory()
        XCTAssertTrue(support?.path.hasSuffix("Application Support/DSH Studio") == true)
        XCTAssertFalse(support?.path.contains("DeepSeek Harness") == true)

        let dshHome = RuntimeLocator.defaultDSHHome()
        XCTAssertTrue(dshHome?.path.hasSuffix("Application Support/DSH Studio/DSH_HOME") == true)
    }

    func testIncompleteActivationRestoresRuntimeMatchingActiveState() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepSeekStudio.RuntimeRecovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let root = support.appendingPathComponent("Runtime", isDirectory: true)
        let backup = RuntimeLocator.rollbackRoot(root: root)
        try makeRuntimeFixture(root: root, runtimeVersion: "new-runtime", harnessVersion: "0.1.0-rc.8")
        try makeRuntimeFixture(root: backup, runtimeVersion: "old-runtime", harnessVersion: "0.1.0-rc.7")

        let state = RuntimeActiveState(
            profileID: "legacy-profile",
            runtimeVersion: "old-runtime",
            dataFormatID: "sqlite-v1"
        )
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(
            to: support.appendingPathComponent("active-state.json"),
            options: .atomic
        )

        XCTAssertTrue(
            RuntimeLocator.recoverIncompleteActivation(
                supportDirectory: support,
                architecture: "darwin-arm64"
            )
        )
        XCTAssertEqual(
            RuntimeLocator.installationManifest(root: root)?.runtimeVersion,
            "old-runtime"
        )
        XCTAssertEqual(
            RuntimeLocator.installationManifest(root: backup)?.runtimeVersion,
            "new-runtime"
        )
    }

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

    private func makeRuntimeFixture(
        root: URL,
        runtimeVersion: String,
        harnessVersion: String
    ) throws {
        let fileManager = FileManager.default
        let architecture = "darwin-arm64"
        let node = RuntimeLocator.nodeExecutable(root: root, architecture: architecture)
        try fileManager.createDirectory(at: node.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho v24.19.0\n".utf8).write(to: node)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: node.path)

        let harness = RuntimeLocator.harnessEntry(
            root: root,
            architecture: architecture,
            harnessVersion: harnessVersion
        )
        try fileManager.createDirectory(at: harness.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env node\n".utf8).write(to: harness)
        let harnessPackage = RuntimeLocator.harnessRoot(
            root: root,
            architecture: architecture,
            harnessVersion: harnessVersion
        ).appendingPathComponent("node_modules/@deepseek-ai/dsh/package.json")
        try Data("{\"name\":\"@deepseek-ai/dsh\",\"version\":\"\(harnessVersion)\"}".utf8)
            .write(to: harnessPackage)

        let pnpm = RuntimeLocator.pnpmExecutable(
            root: root,
            architecture: architecture,
            harnessVersion: harnessVersion
        )
        try fileManager.createDirectory(at: pnpm.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: pnpm)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: pnpm.path)
        let pnpmPackage = RuntimeLocator.pnpmPackageJSON(
            root: root,
            architecture: architecture,
            harnessVersion: harnessVersion
        )
        try fileManager.createDirectory(at: pnpmPackage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"name\":\"pnpm\",\"version\":\"11.7.0\"}".utf8).write(to: pnpmPackage)

        let manifest = RuntimeInstallationManifest(
            runtimeVersion: runtimeVersion,
            architecture: architecture,
            nodeVersion: "24.19.0",
            harnessVersion: harnessVersion,
            nodeSHA256: "node-sha",
            harnessPackageIntegrity: "harness-integrity",
            dataFormat: RuntimeDataFormatDescriptor(id: "sqlite-v1")
        )
        try JSONEncoder().encode(manifest).write(
            to: RuntimeLocator.runtimeManifestURL(root: root),
            options: .atomic
        )
    }
}
