import Foundation
import XCTest
@testable import DeepSeekRuntime

extension RuntimeProvisionerTests {

    func testVersionStatusDetectsCurrentAndRetainsRollbackAfterUpdate() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Runtime", isDirectory: true)
        try makeInstalledFixture(
            root: root,
            architecture: architecture,
            nodeVersion: "24.18.0",
            harnessVersion: "0.1.0-rc.5",
            nodeSHA256: "old-node-sha",
            harnessIntegrity: "old-harness-integrity",
            runtimeVersion: "2026.08.19.1"
        )
        let commandRunner = FixtureCommandRunner()
        let provisioner = RuntimeProvisioner(
            root: root,
            architecture: architecture,
            downloader: FixtureDownloader(data: Data("node archive fixture".utf8)),
            commandRunner: commandRunner,
            packageLockData: try packageLockData(),
            nodeArchiveSHA256Override: fixtureSHA256
        )

        XCTAssertEqual(provisioner.versionStatus().kind, .updateAvailable)
        XCTAssertFalse(provisioner.versionStatus().rollbackAvailable)

        _ = try await provisioner.update()
        let updated = provisioner.versionStatus()
        XCTAssertEqual(updated.kind, .current)
        XCTAssertTrue(updated.rollbackAvailable)
        XCTAssertEqual(
            RuntimeLocator.installationManifest(root: RuntimeLocator.rollbackRoot(root: root))?.harnessVersion,
            "0.1.0-rc.5"
        )

        _ = try provisioner.rollback()
        let rolledBack = provisioner.versionStatus()
        XCTAssertEqual(rolledBack.kind, .updateAvailable)
        XCTAssertTrue(rolledBack.rollbackAvailable)
        XCTAssertEqual(
            RuntimeLocator.installationManifest(root: root)?.harnessVersion,
            "0.1.0-rc.5"
        )
    }

    func testRemoteReleaseUsesVersionedRootWhenLegacyRootIsMissing() throws {
        let support = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }

        let legacyRoot = support.appendingPathComponent("Runtime", isDirectory: true)
        let base = try XCTUnwrap(RuntimeRelease.descriptor(architecture: architecture))
        let remoteRelease = RuntimeReleaseDescriptor(
            architecture: architecture,
            nodeVersion: base.nodeVersion,
            harnessVersion: base.harnessVersion,
            pnpmVersion: base.pnpmVersion,
            nodeArchiveSHA256: base.nodeArchiveSHA256,
            harnessPackageIntegrity: base.harnessPackageIntegrity,
            pnpmPackageIntegrity: base.pnpmPackageIntegrity,
            runtimeVersion: "remote-runtime"
        )
        let provisioner = RuntimeProvisioner(
            root: legacyRoot,
            architecture: architecture,
            release: base
        )

        try provisioner.setRelease(remoteRelease)
        let expectedRoot = try XCTUnwrap(
            RuntimeLocator.versionedRuntimeRoot(
                supportDirectory: support,
                runtimeVersion: "remote-runtime"
            )
        )

        XCTAssertEqual(provisioner.root, expectedRoot)
    }

    func testMissingVersionedRootMovesToSelectedReleaseVersion() throws {
        let support = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let oldRoot = try XCTUnwrap(
            RuntimeLocator.versionedRuntimeRoot(
                supportDirectory: support,
                runtimeVersion: "2026.08.19.1"
            )
        )
        let selectedRelease = try XCTUnwrap(RuntimeRelease.descriptor(architecture: architecture))
        let provisioner = RuntimeProvisioner(
            root: oldRoot,
            architecture: architecture,
            release: selectedRelease
        )

        try provisioner.setRelease(selectedRelease)

        XCTAssertEqual(
            provisioner.root,
            RuntimeLocator.versionedRuntimeRoot(
                supportDirectory: support,
                runtimeVersion: selectedRelease.runtimeVersion
            )
        )
    }

    func testInstalledManifestCanReconstructOfflineReleaseContract() throws {
        let manifest = RuntimeInstallationManifest(
            runtimeVersion: "offline-runtime",
            architecture: architecture,
            nodeVersion: "24.18.0",
            harnessVersion: "0.1.0-rc.7",
            pnpmVersion: "11.6.0",
            nodeSHA256: "node-sha",
            harnessPackageIntegrity: "harness-integrity",
            pnpmPackageIntegrity: "pnpm-integrity",
            dataFormat: RuntimeDataFormatDescriptor(id: "sqlite-v1")
        )

        let release = RuntimeReleaseDescriptor(manifest: manifest)

        XCTAssertEqual(release.runtimeVersion, manifest.runtimeVersion)
        XCTAssertEqual(release.architecture, manifest.architecture)
        XCTAssertEqual(release.nodeVersion, manifest.nodeVersion)
        XCTAssertEqual(release.harnessVersion, manifest.harnessVersion)
        XCTAssertEqual(release.pnpmVersion, manifest.pnpmVersion)
        XCTAssertEqual(release.nodeArchiveSHA256, manifest.nodeSHA256)
        XCTAssertEqual(release.dataFormat, manifest.dataFormat)
        XCTAssertNil(release.artifact)
    }

    func testNewerInstalledRuntimeIsNotDowngradedToOlderAvailableRelease() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Runtime", isDirectory: true)
        try makeInstalledFixture(
            root: root,
            architecture: architecture,
            nodeVersion: RuntimeRelease.nodeVersion,
            harnessVersion: RuntimeRelease.harnessVersion,
            nodeSHA256: fixtureSHA256,
            harnessIntegrity: RuntimeRelease.harnessPackageIntegrity,
            runtimeVersion: "2026.08.22.1"
        )
        let olderRelease = RuntimeReleaseDescriptor(
            architecture: architecture,
            nodeVersion: RuntimeRelease.nodeVersion,
            harnessVersion: RuntimeRelease.harnessVersion,
            pnpmVersion: RuntimeRelease.pnpmVersion,
            nodeArchiveSHA256: fixtureSHA256,
            harnessPackageIntegrity: RuntimeRelease.harnessPackageIntegrity,
            pnpmPackageIntegrity: RuntimeRelease.pnpmPackageIntegrity,
            runtimeVersion: "2026.08.21.1"
        )
        let provisioner = RuntimeProvisioner(
            root: root,
            architecture: architecture,
            packageLockData: try packageLockData(),
            nodeArchiveSHA256Override: fixtureSHA256,
            release: olderRelease
        )

        XCTAssertEqual(provisioner.versionStatus().kind, .newerInstalled)
        XCTAssertFalse(provisioner.versionStatus().updateAvailable)
    }
}
