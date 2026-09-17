import Foundation
import XCTest
@testable import DeepSeekRuntime

/// Validation cases: what must be true before a Runtime is published.
extension RuntimeProvisionerTests {

    /// The lockfile must pin Harness from the official registry.
    func testPackageLockRequiresOfficialRegistryAndPinnedHarness() throws {
        let lock = try packageLockData()
        XCTAssertNoThrow(try RuntimePackageLockValidator.validate(data: lock))

        let mirrorLock = Data(
            String(decoding: lock, as: UTF8.self)
                .replacingOccurrences(of: RuntimeRelease.registryHost, with: "registry.npmmirror.com")
                .utf8
        )
        XCTAssertThrowsError(try RuntimePackageLockValidator.validate(data: mirrorLock)) { error in
            guard case .invalidPackageLock = error as? RuntimeProvisioningError else {
                return XCTFail("expected an invalid package lock error, got \(error)")
            }
        }
    }

    /// The lockfile must pin pnpm as well.
    func testPackageLockRequiresPinnedPnpm() throws {
        let lock = try packageLockData()
        let unpinned = Data(
            String(decoding: lock, as: UTF8.self)
                .replacingOccurrences(of: "\"pnpm\": \"\(RuntimeRelease.pnpmVersion)\"", with: "\"pnpm\": \"11.6.0\"")
                .utf8
        )

        XCTAssertThrowsError(try RuntimePackageLockValidator.validate(data: unpinned)) { error in
            guard case .invalidPackageLock = error as? RuntimeProvisioningError else {
                return XCTFail("expected an invalid pnpm lock error, got \(error)")
            }
        }
    }

    /// An untrusted Node host is rejected before the download starts.
    func testDownloaderRejectsUntrustedNodeHostBeforeTransport() async {
        let downloader = URLSessionRuntimeAssetDownloader()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try await downloader.download(
                from: URL(string: "https://example.com/node.tar.gz")!,
                to: destination
            )
            XCTFail("expected the untrusted host to be rejected")
        } catch let error as RuntimeProvisioningError {
            XCTAssertEqual(
                error,
                .downloadFailed("Runtime 下载地址不是受信任的官方地址")
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// A checksum failure publishes nothing.
    func testChecksumFailureDoesNotPublishPartialRuntime() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Runtime", isDirectory: true)
        let downloader = FixtureDownloader(data: Data("wrong archive".utf8))
        let provisioner = RuntimeProvisioner(
            root: root,
            architecture: architecture,
            downloader: downloader,
            packageLockData: try packageLockData(),
            nodeArchiveSHA256Override: fixtureSHA256
        )

        do {
            _ = try await provisioner.provision()
            XCTFail("expected a checksum failure")
        } catch let error as RuntimeProvisioningError {
            guard case .checksumMismatch = error else {
                return XCTFail("expected checksum mismatch, got \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    /// A validated Runtime is published, and a second run is a no-op.
    func testProvisionerPublishesValidatedRuntimeAndIsIdempotent() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Runtime", isDirectory: true)
        let downloader = FixtureDownloader(data: Data("node archive fixture".utf8))
        let commandRunner = FixtureCommandRunner()
        let provisioner = RuntimeProvisioner(
            root: root,
            architecture: architecture,
            downloader: downloader,
            commandRunner: commandRunner,
            packageLockData: try packageLockData(),
            nodeArchiveSHA256Override: fixtureSHA256
        )

        let first = try await provisioner.provision()
        XCTAssertEqual(first.root, root)
        XCTAssertTrue(
            RuntimeLocator.isComplete(
                root: root,
                architecture: architecture,
                expectedNodeSHA256: fixtureSHA256
            )
        )
        XCTAssertEqual(commandRunner.invocationCount, 2)

        _ = try await provisioner.provision()
        XCTAssertEqual(commandRunner.invocationCount, 2)
        XCTAssertEqual(downloader.downloadCount, 1)
    }
}
