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

private final class ArtifactCommandRunner: RuntimeCommandRunning, @unchecked Sendable {
    private let fileManager = FileManager.default
    private let release: RuntimeReleaseDescriptor
    private let listing: String

    init(
        release: RuntimeReleaseDescriptor,
        listing: String = """
        manifest.json
        node/
        node/darwin-arm64/bin/node
        harness/
        harness/darwin-arm64/0.1.1-rc.2/package.json
        """
    ) {
        self.release = release
        self.listing = listing
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
            runtimeVersion: release.runtimeVersion,
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
