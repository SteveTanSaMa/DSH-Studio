//
//  RuntimeProvisionerTests+Transactions.swift
//  DSH Studio
//

import Foundation
import XCTest
@testable import DeepSeekRuntime

/// Transaction cases: what an interrupted or half-finished update leaves behind.
///
/// The update is a two-phase transaction over two kinds of state — the installed
/// directories and the durable activation record — and these cases pin the invariant
/// that matters after a crash: the Runtime the user was running stays the active one
/// until a replacement has been fully verified.
extension RuntimeProvisionerTests {

    /// An update killed between preparation and activation leaves the old Runtime active.
    func testInterruptedUpdateLeavesThePreviousRuntimeActive() throws {
        let fixture = try makeVersionedUpdateFixture()

        let resolved = RuntimeLocator.runtimeRoot(
            environment: [:],
            supportDirectory: fixture.support
        )

        XCTAssertEqual(resolved.path, fixture.oldRoot.path, "the activated Runtime stays active")
        XCTAssertNotEqual(resolved.path, fixture.newRoot.path, "an unactivated candidate is not active")
        XCTAssertEqual(
            RuntimeLocator.installationManifest(root: resolved)?.runtimeVersion,
            "0.1.0-rc.5"
        )
    }

    /// The prepared candidate is still activatable after that interruption.
    func testTheNextUpdateStillActivatesAfterAnInterruptedOne() throws {
        let fixture = try makeVersionedUpdateFixture()

        XCTAssertEqual(fixture.provisioner.versionStatus().kind, .updatePrepared)

        let activated = try fixture.provisioner.activatePreparedUpdate()

        XCTAssertEqual(activated.root.path, fixture.newRoot.path, "the candidate can be activated")
        XCTAssertEqual(
            fixture.provisioner.versionStatus().installed?.runtimeVersion,
            "0.2.0-rc.2"
        )

        // The previous Runtime is still the rollback target, so the interrupted
        // attempt did not consume the recovery path.
        let rolledBack = try fixture.provisioner.rollback()
        XCTAssertEqual(rolledBack.root.path, fixture.oldRoot.path)
    }

    /// A directory that exists but is not a complete installation is never active.
    func testAnIncompleteDirectoryIsNeverActiveOrCurrent() throws {
        let fixture = try makeVersionedUpdateFixture()
        try FileManager.default.removeItem(at: fixture.newRoot)
        try FileManager.default.createDirectory(at: fixture.newRoot, withIntermediateDirectories: true)
        try Data("not a runtime".utf8)
            .write(to: fixture.newRoot.appendingPathComponent("leftover.txt"))

        let resolved = RuntimeLocator.runtimeRoot(
            environment: [:],
            supportDirectory: fixture.support
        )

        XCTAssertEqual(resolved.path, fixture.oldRoot.path)
        XCTAssertFalse(
            RuntimeLocator.isCompleteInstallation(root: fixture.newRoot, architecture: architecture),
            "a directory without a matching manifest is not an installation"
        )
        XCTAssertEqual(
            fixture.provisioner.versionStatus().kind,
            .updateAvailable,
            "an unusable directory does not count as the update being prepared"
        )
    }

    /// A half-written manifest is not a usable Runtime either.
    func testAMalformedManifestIsNotAUsableRuntime() throws {
        let fixture = try makeVersionedUpdateFixture()
        try Data("{ not json".utf8).write(
            to: RuntimeLocator.runtimeManifestURL(root: fixture.newRoot)
        )

        XCTAssertFalse(
            RuntimeLocator.isCompleteInstallation(root: fixture.newRoot, architecture: architecture)
        )
        XCTAssertEqual(
            RuntimeLocator.runtimeRoot(environment: [:], supportDirectory: fixture.support).path,
            fixture.oldRoot.path
        )
    }

    /// One activated Runtime, one complete unactivated candidate, and an updater for it.
    private struct VersionedUpdateFixture {
        /// Application support directory holding both versions.
        let support: URL
        /// Activated Runtime.
        let oldRoot: URL
        /// Prepared but unactivated Runtime.
        let newRoot: URL
        /// Updater pointed at the activated Runtime, offering the candidate's release.
        let provisioner: RuntimeProvisioner
    }

    /// Builds a versioned installation with an update prepared but not activated.
    ///
    /// - Returns: The directories, the data profile store, and the updater.
    /// - Throws: When the fixtures cannot be written.
    private func makeVersionedUpdateFixture() throws -> VersionedUpdateFixture {
        let support = try makeTemporaryDirectory()
        let oldRoot = try XCTUnwrap(
            RuntimeLocator.versionedRuntimeRoot(supportDirectory: support, runtimeVersion: "0.1.0-rc.5")
        )
        let newRoot = try XCTUnwrap(
            RuntimeLocator.versionedRuntimeRoot(supportDirectory: support, runtimeVersion: "0.2.0-rc.2")
        )
        try makeInstalledFixture(
            root: oldRoot,
            architecture: architecture,
            nodeVersion: "24.18.0",
            harnessVersion: "0.1.0-rc.5",
            nodeSHA256: "old-node-sha",
            harnessIntegrity: "old-harness-integrity",
            runtimeVersion: "0.1.0-rc.5"
        )
        try makeInstalledFixture(
            root: newRoot,
            architecture: architecture,
            nodeVersion: RuntimeRelease.nodeVersion,
            harnessVersion: RuntimeRelease.harnessVersion,
            nodeSHA256: "new-node-sha",
            harnessIntegrity: "new-harness-integrity",
            runtimeVersion: "0.2.0-rc.2"
        )

        let store = RuntimeDataProfileStore(supportDirectory: support)
        let profile = try store.ensureLegacyProfile(
            homeURL: support.appendingPathComponent("DSH_HOME", isDirectory: true)
        )
        let oldManifest = try XCTUnwrap(RuntimeLocator.installationManifest(root: oldRoot))
        let newManifest = try XCTUnwrap(RuntimeLocator.installationManifest(root: newRoot))
        _ = try store.activate(profile: profile, runtimeManifest: oldManifest)

        let release = RuntimeReleaseDescriptor(
            architecture: architecture,
            nodeVersion: newManifest.nodeVersion,
            harnessVersion: newManifest.harnessVersion,
            pnpmVersion: newManifest.pnpmVersion,
            nodeArchiveSHA256: newManifest.nodeSHA256,
            harnessPackageIntegrity: newManifest.harnessPackageIntegrity,
            pnpmPackageIntegrity: newManifest.pnpmPackageIntegrity,
            runtimeVersion: newManifest.runtimeVersion,
            dataFormat: newManifest.dataFormat
        )
        let provisioner = RuntimeProvisioner(
            root: oldRoot,
            architecture: architecture,
            release: release,
            dataProfileStore: store,
            dataProfileID: profile.id
        )
        return VersionedUpdateFixture(
            support: support,
            oldRoot: oldRoot,
            newRoot: newRoot,
            provisioner: provisioner
        )
    }
}
