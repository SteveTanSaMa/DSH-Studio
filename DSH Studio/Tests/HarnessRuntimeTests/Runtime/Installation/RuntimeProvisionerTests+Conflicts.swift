import Foundation
import XCTest
@testable import DeepSeekRuntime

extension RuntimeProvisionerTests {

    func testSameRuntimeVersionConflictCannotOverwriteActiveVersionedRuntime() async throws {
        let support = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let root = try XCTUnwrap(
            RuntimeLocator.versionedRuntimeRoot(
                supportDirectory: support,
                runtimeVersion: "same-runtime"
            )
        )
        try makeInstalledFixture(
            root: root,
            architecture: architecture,
            nodeVersion: "24.18.0",
            harnessVersion: "0.1.0-rc.5",
            nodeSHA256: "old-node-sha",
            harnessIntegrity: "old-harness-integrity",
            runtimeVersion: "same-runtime"
        )
        let release = RuntimeReleaseDescriptor(
            architecture: architecture,
            nodeVersion: RuntimeRelease.nodeVersion,
            harnessVersion: RuntimeRelease.harnessVersion,
            pnpmVersion: RuntimeRelease.pnpmVersion,
            nodeArchiveSHA256: fixtureSHA256,
            harnessPackageIntegrity: RuntimeRelease.harnessPackageIntegrity,
            pnpmPackageIntegrity: RuntimeRelease.pnpmPackageIntegrity,
            runtimeVersion: "same-runtime"
        )
        let provisioner = RuntimeProvisioner(
            root: root,
            architecture: architecture,
            downloader: FixtureDownloader(data: Data("must not download".utf8)),
            packageLockData: try packageLockData(),
            nodeArchiveSHA256Override: fixtureSHA256,
            release: release
        )

        XCTAssertEqual(provisioner.versionStatus().kind, RuntimeVersionStatusKind.invalid)
        do {
            _ = try await provisioner.prepareUpdate()
            XCTFail("expected same-version Runtime conflict")
        } catch let error as RuntimeProvisioningError {
            guard case .runtimeValidationFailed = error else {
                return XCTFail("expected Runtime validation failure, got (error)")
            }
        }
        XCTAssertEqual(
            RuntimeLocator.installationManifest(root: root)?.harnessVersion,
            "0.1.0-rc.5"
        )
    }

    func testSameRuntimeVersionConflictCannotOverwritePreparedCandidate() async throws {
        let support = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let oldRoot = try XCTUnwrap(
            RuntimeLocator.versionedRuntimeRoot(
                supportDirectory: support,
                runtimeVersion: "old-runtime"
            )
        )
        let candidateRoot = try XCTUnwrap(
            RuntimeLocator.versionedRuntimeRoot(
                supportDirectory: support,
                runtimeVersion: "same-runtime"
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
            root: candidateRoot,
            architecture: architecture,
            nodeVersion: "24.18.0",
            harnessVersion: "0.1.0-rc.5",
            nodeSHA256: "candidate-node-sha",
            harnessIntegrity: "candidate-harness-integrity",
            runtimeVersion: "same-runtime"
        )
        let base = try XCTUnwrap(RuntimeRelease.descriptor(architecture: architecture))
        let release = RuntimeReleaseDescriptor(
            architecture: architecture,
            nodeVersion: base.nodeVersion,
            harnessVersion: base.harnessVersion,
            pnpmVersion: base.pnpmVersion,
            nodeArchiveSHA256: fixtureSHA256,
            harnessPackageIntegrity: base.harnessPackageIntegrity,
            pnpmPackageIntegrity: base.pnpmPackageIntegrity,
            runtimeVersion: "same-runtime"
        )
        let downloader = FixtureDownloader(data: Data("must not download".utf8))
        let provisioner = RuntimeProvisioner(
            root: oldRoot,
            architecture: architecture,
            downloader: downloader,
            packageLockData: try packageLockData(),
            nodeArchiveSHA256Override: fixtureSHA256,
            release: release
        )

        XCTAssertEqual(provisioner.versionStatus().kind, .updateBlocked)
        do {
            _ = try await provisioner.prepareUpdate()
            XCTFail("expected same-version candidate conflict")
        } catch let error as RuntimeProvisioningError {
            guard case .runtimeValidationFailed = error else {
                return XCTFail("expected Runtime validation failure, got \(error)")
            }
        }
        XCTAssertEqual(downloader.downloadCount, 0)
        XCTAssertEqual(
            RuntimeLocator.installationManifest(root: candidateRoot)?.nodeSHA256,
            "candidate-node-sha"
        )
    }

    func testLegacyRuntimeCannotIgnoreConflictingVersionedInstallation() async throws {
        let support = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let legacyRoot = support.appendingPathComponent("Runtime", isDirectory: true)
        let versionedRoot = try XCTUnwrap(
            RuntimeLocator.versionedRuntimeRoot(
                supportDirectory: support,
                runtimeVersion: "same-runtime"
            )
        )
        try makeInstalledFixture(
            root: legacyRoot,
            architecture: architecture,
            nodeVersion: "24.18.0",
            harnessVersion: "0.1.0-rc.5",
            nodeSHA256: "old-node-sha",
            harnessIntegrity: "old-harness-integrity",
            runtimeVersion: "legacy-runtime"
        )
        try makeInstalledFixture(
            root: versionedRoot,
            architecture: architecture,
            nodeVersion: "24.18.0",
            harnessVersion: "0.1.0-rc.5",
            nodeSHA256: "conflicting-node-sha",
            harnessIntegrity: "conflicting-harness-integrity",
            runtimeVersion: "same-runtime"
        )
        let base = try XCTUnwrap(RuntimeRelease.descriptor(architecture: architecture))
        let release = RuntimeReleaseDescriptor(
            architecture: architecture,
            nodeVersion: base.nodeVersion,
            harnessVersion: base.harnessVersion,
            pnpmVersion: base.pnpmVersion,
            nodeArchiveSHA256: fixtureSHA256,
            harnessPackageIntegrity: base.harnessPackageIntegrity,
            pnpmPackageIntegrity: base.pnpmPackageIntegrity,
            runtimeVersion: "same-runtime"
        )
        let downloader = FixtureDownloader(data: Data("must not download".utf8))
        let provisioner = RuntimeProvisioner(
            root: legacyRoot,
            architecture: architecture,
            downloader: downloader,
            packageLockData: try packageLockData(),
            nodeArchiveSHA256Override: fixtureSHA256,
            release: release
        )

        XCTAssertEqual(provisioner.versionStatus().kind, .updateBlocked)
        do {
            _ = try await provisioner.prepareUpdate()
            XCTFail("expected legacy/versioned same-version conflict")
        } catch let error as RuntimeProvisioningError {
            guard case .runtimeValidationFailed = error else {
                return XCTFail("expected Runtime validation failure, got \(error)")
            }
        }
        XCTAssertEqual(downloader.downloadCount, 0)
        XCTAssertEqual(
            RuntimeLocator.installationManifest(root: versionedRoot)?.nodeSHA256,
            "conflicting-node-sha"
        )
    }
}
