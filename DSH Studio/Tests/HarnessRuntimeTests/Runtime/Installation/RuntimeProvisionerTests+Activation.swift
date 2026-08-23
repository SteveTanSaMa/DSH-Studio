import Foundation
import XCTest
@testable import DeepSeekRuntime

extension RuntimeProvisionerTests {

    func testVersionedRuntimeActivationAndRollbackUseActiveStatePair() throws {
        let support = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }

        let oldRoot = try XCTUnwrap(
            RuntimeLocator.versionedRuntimeRoot(
                supportDirectory: support,
                runtimeVersion: "old-runtime"
            )
        )
        let newRoot = try XCTUnwrap(
            RuntimeLocator.versionedRuntimeRoot(
                supportDirectory: support,
                runtimeVersion: "new-runtime"
            )
        )
        try makeInstalledFixture(
            root: oldRoot,
            architecture: architecture,
            nodeVersion: "24.18.0",
            harnessVersion: "0.1.0-rc.5",
            nodeSHA256: "old-node-sha",
            harnessIntegrity: "old-harness-integrity",
            runtimeVersion: "old-runtime"
        )
        try makeInstalledFixture(
            root: newRoot,
            architecture: architecture,
            nodeVersion: RuntimeRelease.nodeVersion,
            harnessVersion: RuntimeRelease.harnessVersion,
            nodeSHA256: "new-node-sha",
            harnessIntegrity: "new-harness-integrity",
            runtimeVersion: "new-runtime"
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

        let activated = try provisioner.activatePreparedUpdate()
        XCTAssertEqual(activated.root, newRoot)
        XCTAssertEqual(provisioner.root, newRoot)

        _ = try store.activate(profile: profile, runtimeManifest: newManifest)
        XCTAssertTrue(provisioner.versionStatus().rollbackAvailable)

        let rolledBack = try provisioner.rollback()
        XCTAssertEqual(rolledBack.root, oldRoot)
        XCTAssertEqual(provisioner.root, oldRoot)
        XCTAssertEqual(
            RuntimeLocator.installationManifest(root: provisioner.root)?.runtimeVersion,
            "old-runtime"
        )
    }

    func testFailedUpdateLeavesActiveRuntimeUntouched() async throws {
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
            runtimeVersion: "old-runtime"
        )
        let provisioner = RuntimeProvisioner(
            root: root,
            architecture: architecture,
            downloader: FixtureDownloader(data: Data("wrong archive".utf8)),
            packageLockData: try packageLockData(),
            nodeArchiveSHA256Override: fixtureSHA256
        )

        do {
            _ = try await provisioner.update()
            XCTFail("expected a checksum failure")
        } catch let error as RuntimeProvisioningError {
            guard case .checksumMismatch = error else {
                return XCTFail("expected checksum mismatch, got \(error)")
            }
        }

        XCTAssertEqual(
            RuntimeLocator.installationManifest(root: root)?.harnessVersion,
            "0.1.0-rc.5"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: RuntimeLocator.rollbackRoot(root: root).path))
    }

    func testCancellationCleansStagingWithoutPublishingRuntime() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Runtime", isDirectory: true)
        let provisioner = RuntimeProvisioner(
            root: root,
            architecture: architecture,
            downloader: CancellableDownloader(),
            packageLockData: try packageLockData(),
            nodeArchiveSHA256Override: fixtureSHA256
        )

        let task = Task {
            try await provisioner.provision()
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected provisioning cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }
}
