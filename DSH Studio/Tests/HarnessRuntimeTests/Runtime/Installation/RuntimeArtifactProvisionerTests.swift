//
//  RuntimeArtifactProvisionerTests.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import Foundation
import XCTest
@testable import DeepSeekRuntime

/// Verifies immutable Runtime artifact extraction, validation, and publication.
final class RuntimeArtifactProvisionerTests: XCTestCase {
    private let architecture = "darwin-arm64"
    private let artifactFixtureSHA256 = "7d4090092b093f82826d57849faa8e9471059c6e5977ba484b8c4fa6e306c3d9"

    /// A checksum failure leaves no partial Runtime behind.
    func testArtifactChecksumFailureDoesNotPublishPartialRuntime() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Runtime", isDirectory: true)
        let release = makeArtifactRelease(sha256: String(repeating: "0", count: 64))
        let provisioner = RuntimeProvisioner(
            root: root,
            architecture: architecture,
            downloader: FixtureDownloader(data: Data("artifact archive fixture".utf8)),
            commandRunner: ArtifactCommandRunner(release: release),
            release: release
        )

        do {
            _ = try await provisioner.provision()
            XCTFail("expected an artifact checksum failure")
        } catch let error as RuntimeProvisioningError {
            guard case .checksumMismatch = error else {
                return XCTFail("expected checksum mismatch, got \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    /// The artifact is extracted and validated before anything is published.
    func testArtifactIsExtractedAndValidatedBeforePublication() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Runtime", isDirectory: true)
        let release = makeArtifactRelease(sha256: artifactFixtureSHA256)
        let provisioner = RuntimeProvisioner(
            root: root,
            architecture: architecture,
            downloader: FixtureDownloader(data: Data("artifact archive fixture".utf8)),
            commandRunner: ArtifactCommandRunner(release: release),
            release: release
        )

        let result = try await provisioner.provision()

        XCTAssertEqual(result.manifest.runtimeVersion, release.runtimeVersion)
        XCTAssertTrue(
            RuntimeLocator.isComplete(
                root: root,
                architecture: architecture,
                expectedNodeVersion: release.nodeVersion,
                expectedHarnessVersion: release.harnessVersion,
                expectedPnpmVersion: release.pnpmVersion,
                expectedNodeSHA256: release.nodeArchiveSHA256,
                expectedRelease: release
            )
        )
    }

    /// An archive with traversal paths is rejected before extraction starts.
    func testArtifactTraversalIsRejectedBeforeExtraction() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Runtime", isDirectory: true)
        let release = makeArtifactRelease(sha256: artifactFixtureSHA256)
        let provisioner = RuntimeProvisioner(
            root: root,
            architecture: architecture,
            downloader: FixtureDownloader(data: Data("artifact archive fixture".utf8)),
            commandRunner: ArtifactCommandRunner(
                release: release,
                listing: "manifest.json\nnode/\nharness/\n../../outside\n"
            ),
            release: release
        )

        do {
            _ = try await provisioner.provision()
            XCTFail("expected an unsafe archive listing failure")
        } catch let error as RuntimeProvisioningError {
            guard case .runtimeValidationFailed = error else {
                return XCTFail("expected archive validation failure, got \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    /// An update whose archive cannot be extracted leaves the active Runtime usable.
    func testInterruptedExtractionLeavesTheActiveRuntimeUsable() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Runtime", isDirectory: true)
        let release = makeArtifactRelease(sha256: artifactFixtureSHA256)
        let installed = try await RuntimeProvisioner(
            root: root,
            architecture: architecture,
            downloader: FixtureDownloader(data: Data("artifact archive fixture".utf8)),
            commandRunner: ArtifactCommandRunner(release: release),
            release: release
        ).provision()
        XCTAssertTrue(RuntimeLocator.isCompleteInstallation(root: root, architecture: architecture))

        let interrupted = RuntimeProvisioner(
            root: root,
            architecture: architecture,
            downloader: FixtureDownloader(data: Data("artifact archive fixture".utf8)),
            commandRunner: ArtifactCommandRunner(release: release, extractionStatus: 1),
            release: release
        )
        do {
            _ = try await interrupted.update()
            XCTFail("expected an extraction failure")
        } catch let error as RuntimeProvisioningError {
            guard case .commandFailed = error else {
                return XCTFail("expected a command failure, got \(error)")
            }
        }

        XCTAssertEqual(
            RuntimeLocator.installationManifest(root: root)?.runtimeVersion,
            installed.manifest.runtimeVersion,
            "the active Runtime is the one that keeps running"
        )
        XCTAssertTrue(
            RuntimeLocator.isCompleteInstallation(root: root, architecture: architecture),
            "and it is still a usable installation"
        )
    }

    /// An archive whose manifest disagrees with the catalog is never published.
    func testManifestMismatchIsRejectedBeforePublication() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Runtime", isDirectory: true)
        let release = makeArtifactRelease(sha256: artifactFixtureSHA256)
        let provisioner = RuntimeProvisioner(
            root: root,
            architecture: architecture,
            downloader: FixtureDownloader(data: Data("artifact archive fixture".utf8)),
            commandRunner: ArtifactCommandRunner(release: release, manifestRuntimeVersion: "0.0.0-other"),
            release: release
        )

        do {
            _ = try await provisioner.provision()
            XCTFail("expected a manifest mismatch")
        } catch let error as RuntimeProvisioningError {
            guard case .runtimeValidationFailed = error else {
                return XCTFail("expected a manifest validation failure, got \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    /// A verified archive from an earlier attempt is reused instead of downloaded again.
    func testVerifiedArchiveInTheCacheIsReused() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Runtime", isDirectory: true)
        let cache = parent.appendingPathComponent("RuntimeDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let release = makeArtifactRelease(sha256: artifactFixtureSHA256)
        let fixture = Data("artifact archive fixture".utf8)
        try fixture.write(to: cache.appendingPathComponent("\(artifactFixtureSHA256).tar.gz"))
        let downloader = RecordingArtifactDownloader(data: fixture)

        _ = try await RuntimeProvisioner(
            root: root,
            architecture: architecture,
            downloader: downloader,
            commandRunner: ArtifactCommandRunner(release: release),
            release: release,
            downloadCacheDirectory: cache
        ).provision()

        XCTAssertTrue(downloader.downloads.isEmpty, "a verified archive must not be downloaded again")
        XCTAssertTrue(RuntimeLocator.isCompleteInstallation(root: root, architecture: architecture))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: cache.appendingPathComponent("\(artifactFixtureSHA256).tar.gz").path
            ),
            "the verified archive stays cached for the next attempt"
        )
    }

    /// A cached archive that does not match the catalog is discarded, not trusted.
    func testACorruptCachedArchiveIsDiscardedAndDownloadedAgain() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Runtime", isDirectory: true)
        let cache = parent.appendingPathComponent("RuntimeDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let release = makeArtifactRelease(sha256: artifactFixtureSHA256)
        let cached = cache.appendingPathComponent("\(artifactFixtureSHA256).tar.gz")
        try Data("not the artifact".utf8).write(to: cached)
        let downloader = RecordingArtifactDownloader(data: Data("artifact archive fixture".utf8))

        _ = try await RuntimeProvisioner(
            root: root,
            architecture: architecture,
            downloader: downloader,
            commandRunner: ArtifactCommandRunner(release: release),
            release: release,
            downloadCacheDirectory: cache
        ).provision()

        XCTAssertEqual(downloader.downloads.count, 1, "a cached archive that fails the checksum is replaced")
        XCTAssertTrue(RuntimeLocator.isCompleteInstallation(root: root, architecture: architecture))
    }

    /// An unfinished download is continued rather than restarted.
    func testAnUnfinishedDownloadIsContinued() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Runtime", isDirectory: true)
        let cache = parent.appendingPathComponent("RuntimeDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let release = makeArtifactRelease(sha256: artifactFixtureSHA256)
        let partial = cache.appendingPathComponent("\(artifactFixtureSHA256).partial")
        try Data("half an artifact".utf8).write(to: partial)
        let downloader = RecordingArtifactDownloader(data: Data("artifact archive fixture".utf8))

        _ = try await RuntimeProvisioner(
            root: root,
            architecture: architecture,
            downloader: downloader,
            commandRunner: ArtifactCommandRunner(release: release),
            release: release,
            downloadCacheDirectory: cache
        ).provision()

        XCTAssertEqual(downloader.downloads.first?.resumingFrom?.path, partial.path)
        XCTAssertTrue(RuntimeLocator.isCompleteInstallation(root: root, architecture: architecture))
    }

    /// Bytes left by a transfer that failed are used when they are the artifact.
    func testBytesLeftByAFailedTransferAreUsedWhenTheyMatch() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Runtime", isDirectory: true)
        let cache = parent.appendingPathComponent("RuntimeDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let release = makeArtifactRelease(sha256: artifactFixtureSHA256)
        let partial = cache.appendingPathComponent("\(artifactFixtureSHA256).partial")
        try Data("artifact archive fixture".utf8).write(to: partial)
        let downloader = RecordingArtifactDownloader(data: Data("artifact archive fixture".utf8))
        downloader.error = RuntimeProvisioningError.downloadFailed("connection lost")

        _ = try await RuntimeProvisioner(
            root: root,
            architecture: architecture,
            downloader: downloader,
            commandRunner: ArtifactCommandRunner(release: release),
            release: release,
            downloadCacheDirectory: cache
        ).provision()

        XCTAssertTrue(
            RuntimeLocator.isCompleteInstallation(root: root, architecture: architecture),
            "a partial that matches the catalog checksum is the artifact"
        )
    }

    /// Bytes that are not the artifact are dropped when a transfer fails.
    func testBytesLeftByAFailedTransferAreDroppedWhenTheyDoNotMatch() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Runtime", isDirectory: true)
        let cache = parent.appendingPathComponent("RuntimeDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let release = makeArtifactRelease(sha256: artifactFixtureSHA256)
        let partial = cache.appendingPathComponent("\(artifactFixtureSHA256).partial")
        try Data("debris".utf8).write(to: partial)
        let downloader = RecordingArtifactDownloader(data: Data("artifact archive fixture".utf8))
        downloader.error = RuntimeProvisioningError.downloadFailed("connection lost")

        do {
            _ = try await RuntimeProvisioner(
                root: root,
                architecture: architecture,
                downloader: downloader,
                commandRunner: ArtifactCommandRunner(release: release),
                release: release,
                downloadCacheDirectory: cache
            ).provision()
            XCTFail("expected the download failure to surface")
        } catch let error as RuntimeProvisioningError {
            guard case .downloadFailed = error else {
                return XCTFail("expected a download failure, got \(error)")
            }
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: partial.path),
            "debris must not be continued from on the next attempt"
        )
    }

    /// Cached downloads for other builds are evicted once a build is installed.
    func testCachedArtifactsForOtherBuildsAreEvicted() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Runtime", isDirectory: true)
        let cache = parent.appendingPathComponent("RuntimeDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let stale = cache.appendingPathComponent("0000000000000000000000000000000000000000000000000000000000000000.tar.gz")
        try Data("an older build".utf8).write(to: stale)
        let release = makeArtifactRelease(sha256: artifactFixtureSHA256)

        _ = try await RuntimeProvisioner(
            root: root,
            architecture: architecture,
            downloader: RecordingArtifactDownloader(data: Data("artifact archive fixture".utf8)),
            commandRunner: ArtifactCommandRunner(release: release),
            release: release,
            downloadCacheDirectory: cache
        ).provision()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "older builds are dropped")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: cache.appendingPathComponent("\(artifactFixtureSHA256).tar.gz").path
            ),
            "the installed artifact's archive is kept"
        )
    }

    private func makeArtifactRelease(sha256: String) -> RuntimeReleaseDescriptor {
        let runtimeVersion = "2026.08.20.test"
        return RuntimeReleaseDescriptor(
            architecture: architecture,
            nodeVersion: RuntimeRelease.nodeVersion,
            harnessVersion: RuntimeRelease.harnessVersion,
            pnpmVersion: RuntimeRelease.pnpmVersion,
            nodeArchiveSHA256: String(repeating: "d", count: 64),
            harnessPackageIntegrity: RuntimeRelease.harnessPackageIntegrity,
            pnpmPackageIntegrity: RuntimeRelease.pnpmPackageIntegrity,
            runtimeVersion: runtimeVersion,
            artifact: RuntimeArtifactDescriptor(
                runtimeVersion: runtimeVersion,
                architecture: architecture,
                url: URL(string: "https://github.com/SteveTanSaMa/DSH-Studio-Runtime/releases/download/runtime-\(runtimeVersion)/dsh-runtime-\(runtimeVersion)-\(architecture).tar.gz")!,
                sha256: sha256
            )
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Records the artifact downloads a provisioner asks for, and can fail them.
private final class RecordingArtifactDownloader: RuntimeAssetDownloading, @unchecked Sendable {
    /// One recorded request.
    struct Download: Equatable {
        /// Trusted artifact URL that was requested.
        let url: URL
        /// File the artifact was written to.
        let destination: URL
        /// Partial file the request continued, when there was one.
        let resumingFrom: URL?
    }

    private let data: Data
    private let lock = NSLock()
    private var stored: [Download] = []
    /// When set, the transfer fails with this error after being recorded.
    var error: Error?

    /// Downloads recorded so far.
    var downloads: [Download] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// Creates a downloader that writes fixed bytes.
    ///
    /// - Parameter data: Bytes written to every destination.
    init(data: Data) {
        self.data = data
    }

    /// Records the request and writes the fixture bytes.
    ///
    /// - Parameters:
    ///   - url: Requested artifact URL.
    ///   - destination: File that receives the fixture bytes.
    /// - Throws: The configured error, when one is set.
    func download(from url: URL, to destination: URL) async throws {
        try await download(from: url, to: destination, onProgress: nil)
    }

    /// Records the request and writes the fixture bytes.
    ///
    /// - Parameters:
    ///   - url: Requested artifact URL.
    ///   - destination: File that receives the fixture bytes.
    ///   - onProgress: Receives the fixture size once.
    /// - Throws: The configured error, when one is set.
    func download(
        from url: URL,
        to destination: URL,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws {
        try await download(from: url, to: destination, resumingFrom: nil, onProgress: onProgress)
    }

    /// Records the request, including the partial file it was asked to continue.
    ///
    /// - Parameters:
    ///   - url: Requested artifact URL.
    ///   - destination: File that receives the fixture bytes.
    ///   - partial: Partial file the request continues, when there is one.
    ///   - onProgress: Receives the fixture size once.
    /// - Throws: The configured error, when one is set.
    func download(
        from url: URL,
        to destination: URL,
        resumingFrom partial: URL?,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws {
        lock.lock()
        stored.append(Download(url: url, destination: destination, resumingFrom: partial))
        let failure = error
        lock.unlock()
        if let failure { throw failure }
        try data.write(to: destination)
        onProgress?(Int64(data.count), Int64(data.count))
    }
}

private final class ArtifactCommandRunner: RuntimeCommandRunning, @unchecked Sendable {
    private let fileManager = FileManager.default
    private let release: RuntimeReleaseDescriptor
    private let listing: String
    /// Status the extraction command reports; non-zero simulates an interrupted unpack.
    private let extractionStatus: Int32
    /// Runtime version the extracted manifest claims, when it must differ from the catalog.
    private let manifestRuntimeVersion: String?

    init(
        release: RuntimeReleaseDescriptor,
        listing: String = """
        manifest.json
        node/
        node/darwin-arm64/bin/node
        harness/
        harness/darwin-arm64/0.1.1-rc.2/package.json
        """,
        extractionStatus: Int32 = 0,
        manifestRuntimeVersion: String? = nil
    ) {
        self.release = release
        self.listing = listing
        self.extractionStatus = extractionStatus
        self.manifestRuntimeVersion = manifestRuntimeVersion
    }

    func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String]
    ) throws -> RuntimeCommandResult {
        if arguments.first == "-tzf" {
            return RuntimeCommandResult(status: 0, stdout: listing, stderr: "")
        }
        guard arguments.first == "-xzf",
              let index = arguments.firstIndex(of: "-C"),
              arguments.indices.contains(index + 1) else {
            return RuntimeCommandResult(status: 0, stdout: "", stderr: "")
        }
        guard extractionStatus == 0 else {
            return RuntimeCommandResult(status: extractionStatus, stdout: "", stderr: "unpack interrupted")
        }

        let root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        let node = RuntimeLocator.nodeExecutable(root: root, architecture: release.architecture)
        try fileManager.createDirectory(at: node.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho v\(release.nodeVersion)\n".utf8).write(to: node)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: node.path)

        let entry = RuntimeLocator.harnessEntry(
            root: root,
            architecture: release.architecture,
            harnessVersion: release.harnessVersion
        )
        try fileManager.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env node\n".utf8).write(to: entry)
        let harnessPackage = RuntimeLocator.harnessRoot(
            root: root,
            architecture: release.architecture,
            harnessVersion: release.harnessVersion
        )
            .appendingPathComponent("node_modules/@deepseek-ai/dsh/package.json")
        try Data("{\"name\":\"@deepseek-ai/dsh\",\"version\":\"\(release.harnessVersion)\"}".utf8)
            .write(to: harnessPackage)

        let pnpmPackage = RuntimeLocator.pnpmPackageJSON(
            root: root,
            architecture: release.architecture,
            harnessVersion: release.harnessVersion
        )
        try fileManager.createDirectory(at: pnpmPackage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"name\":\"pnpm\",\"version\":\"\(release.pnpmVersion)\"}".utf8)
            .write(to: pnpmPackage)
        let pnpmShim = RuntimeLocator.pnpmExecutable(
            root: root,
            architecture: release.architecture,
            harnessVersion: release.harnessVersion
        )
        try fileManager.createDirectory(at: pnpmShim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: pnpmShim)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: pnpmShim.path)

        let nativeRoot = RuntimeLocator.harnessRoot(
            root: root,
            architecture: release.architecture,
            harnessVersion: release.harnessVersion
        )
            .appendingPathComponent("node_modules/node-pty/prebuilds/\(release.architecture)", isDirectory: true)
        try fileManager.createDirectory(at: nativeRoot, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: nativeRoot.appendingPathComponent("pty.node"))
        let helper = nativeRoot.appendingPathComponent("spawn-helper")
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: helper.path)

        let manifest = RuntimeInstallationManifest(
            runtimeVersion: manifestRuntimeVersion ?? release.runtimeVersion,
            architecture: release.architecture,
            nodeVersion: release.nodeVersion,
            harnessVersion: release.harnessVersion,
            pnpmVersion: release.pnpmVersion,
            nodeSHA256: release.nodeArchiveSHA256,
            harnessPackageIntegrity: release.harnessPackageIntegrity,
            pnpmPackageIntegrity: release.pnpmPackageIntegrity
        )
        try JSONEncoder().encode(manifest).write(to: RuntimeLocator.runtimeManifestURL(root: root), options: .atomic)
        return RuntimeCommandResult(status: 0, stdout: "", stderr: "")
    }
}
