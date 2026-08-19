//
//  RuntimeProvisionerTests.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
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
                .downloadFailed("Runtime 下载地址不是受信任的 Node.js 官方地址")
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
        let integrity = RuntimeRelease.harnessPackageIntegrity
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
                "@deepseek-ai/dsh": "0.1.0-rc.6"
              }
            },
            "node_modules/@deepseek-ai/dsh": {
              "version": "0.1.0-rc.6",
              "resolved": "https://registry.npmjs.org/@deepseek-ai/dsh/-/dsh-0.1.0-rc.6.tgz",
              "integrity": "\(integrity)"
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
}

private struct FixtureDownloader: RuntimeAssetDownloading {
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
