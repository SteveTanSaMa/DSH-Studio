//
//  RuntimeProvisionerTests.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import Foundation
import XCTest
@testable import DeepSeekRuntime

/// Verifies pinned downloads, checksums, staging, and cancellation cleanup.
final class RuntimeProvisionerTests: XCTestCase {
    private let architecture = "darwin-arm64"
    private let fixtureSHA256 = "58d6dca829b124ec89d74c20bc88df55e086531559c841582de076a9157c4bb3"

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
            harnessIntegrity: "old-harness-integrity"
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
            harnessIntegrity: "old-harness-integrity"
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

    private func packageLockData() throws -> Data {
        let harnessIntegrity = RuntimeRelease.harnessPackageIntegrity
        let pnpmIntegrity = RuntimeRelease.pnpmPackageIntegrity
        let json = """
        {
          "name": "deepseek-harness-macos-runtime",
          "version": "0.0.1",
          "lockfileVersion": 3,
          "requires": true,
          "packages": {
            "": {
              "name": "deepseek-harness-macos-runtime",
              "version": "0.0.1",
              "dependencies": {
                "@deepseek-ai/dsh": "0.1.0-rc.6",
                "pnpm": "\(RuntimeRelease.pnpmVersion)"
              }
            },
            "node_modules/@deepseek-ai/dsh": {
              "version": "0.1.0-rc.6",
              "resolved": "https://registry.npmjs.org/@deepseek-ai/dsh/-/dsh-0.1.0-rc.6.tgz",
              "integrity": "\(harnessIntegrity)"
            },
            "node_modules/pnpm": {
              "version": "\(RuntimeRelease.pnpmVersion)",
              "resolved": "https://registry.npmjs.org/pnpm/-/pnpm-\(RuntimeRelease.pnpmVersion).tgz",
              "integrity": "\(pnpmIntegrity)"
            }
          }
        }
        """
        return try XCTUnwrap(json.data(using: .utf8))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeInstalledFixture(
        root: URL,
        architecture: String,
        nodeVersion: String,
        harnessVersion: String,
        nodeSHA256: String,
        harnessIntegrity: String
    ) throws {
        let fileManager = FileManager.default
        let node = RuntimeLocator.nodeExecutable(root: root, architecture: architecture)
        try fileManager.createDirectory(at: node.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho v\(nodeVersion)\n".utf8).write(to: node)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: node.path)

        let entry = RuntimeLocator.harnessEntry(
            root: root,
            architecture: architecture,
            harnessVersion: harnessVersion
        )
        try fileManager.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env node\n".utf8).write(to: entry)
        let package = entry
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("package.json")
        try Data("{\"name\":\"@deepseek-ai/dsh\",\"version\":\"\(harnessVersion)\"}".utf8)
            .write(to: package)

        let pnpmPackage = RuntimeLocator.pnpmPackageJSON(
            root: root,
            architecture: architecture,
            harnessVersion: harnessVersion
        )
        try fileManager.createDirectory(at: pnpmPackage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"name\":\"pnpm\",\"version\":\"\(RuntimeRelease.pnpmVersion)\"}".utf8)
            .write(to: pnpmPackage)
        let pnpmShim = RuntimeLocator.pnpmExecutable(
            root: root,
            architecture: architecture,
            harnessVersion: harnessVersion
        )
        try fileManager.createDirectory(at: pnpmShim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: pnpmShim)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: pnpmShim.path)

        let manifest = RuntimeInstallationManifest(
            architecture: architecture,
            nodeVersion: nodeVersion,
            harnessVersion: harnessVersion,
            nodeSHA256: nodeSHA256,
            harnessPackageIntegrity: harnessIntegrity
        )
        let data = try JSONEncoder().encode(manifest)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: RuntimeLocator.runtimeManifestURL(root: root), options: .atomic)
    }
}

struct FixtureDownloader: RuntimeAssetDownloading {
    let data: Data
    private let counter = Counter()

    var downloadCount: Int { counter.value }

    func download(from url: URL, to destination: URL) async throws {
        counter.increment()
        try data.write(to: destination)
    }
}

private struct CancellableDownloader: RuntimeAssetDownloading {
    func download(from url: URL, to destination: URL) async throws {
        try Task.checkCancellation()
        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}

private final class FixtureCommandRunner: RuntimeCommandRunning, @unchecked Sendable {
    private let fileManager = FileManager.default
    private(set) var invocationCount = 0

    func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String]
    ) throws -> RuntimeCommandResult {
        invocationCount += 1
        if arguments.first == "-xzf", let index = arguments.firstIndex(of: "-C"), arguments.indices.contains(index + 1) {
            let nodeRoot = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            let node = nodeRoot.appendingPathComponent("bin/node")
            try fileManager.createDirectory(at: node.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\necho v24.19.0\n".utf8).write(to: node)
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: node.path)

            let npmCLI = nodeRoot.appendingPathComponent("lib/node_modules/npm/bin/npm-cli.js")
            try fileManager.createDirectory(at: npmCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("// fixture\n".utf8).write(to: npmCLI)
        } else if arguments.contains("ci") {
            let harnessPackage = currentDirectory
                .appendingPathComponent("node_modules/@deepseek-ai/dsh", isDirectory: true)
            let entry = harnessPackage.appendingPathComponent("lib/bin.js")
            try fileManager.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/usr/bin/env node\n".utf8).write(to: entry)
            let packageJSON = "{\"name\":\"@deepseek-ai/dsh\",\"version\":\"0.1.0-rc.6\"}"
            try Data(packageJSON.utf8).write(to: harnessPackage.appendingPathComponent("package.json"))

            let pnpmPackage = currentDirectory
                .appendingPathComponent("node_modules/pnpm", isDirectory: true)
            try fileManager.createDirectory(at: pnpmPackage, withIntermediateDirectories: true)
            try Data("{\"name\":\"pnpm\",\"version\":\"\(RuntimeRelease.pnpmVersion)\"}".utf8)
                .write(to: pnpmPackage.appendingPathComponent("package.json"))
            let pnpmShim = currentDirectory
                .appendingPathComponent("node_modules/.bin/pnpm", isDirectory: false)
            try fileManager.createDirectory(at: pnpmShim.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: pnpmShim)
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: pnpmShim.path)

            let nativeDirectory = currentDirectory
                .appendingPathComponent("node_modules/node-pty/prebuilds/darwin-arm64", isDirectory: true)
            try fileManager.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: nativeDirectory.appendingPathComponent("pty.node"))
            let helper = nativeDirectory.appendingPathComponent("spawn-helper")
            try Data("#!/bin/sh\n".utf8).write(to: helper)
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: helper.path)
        }
        return RuntimeCommandResult(status: 0, stdout: "", stderr: "")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
