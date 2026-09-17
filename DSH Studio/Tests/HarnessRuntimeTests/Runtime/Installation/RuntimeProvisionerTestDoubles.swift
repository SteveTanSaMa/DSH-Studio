import Foundation
import XCTest
@testable import DeepSeekRuntime

/// Writes fixed bytes as the downloaded artifact and counts the calls.
///
/// The counter is a lock-protected box so the double stays usable from the
/// detached provisioning tasks the tests exercise.
struct FixtureDownloader: RuntimeAssetDownloading {
    /// Bytes written to every download destination.
    let data: Data
    private let counter = Counter()

    /// Number of downloads performed so far.
    var downloadCount: Int { counter.value }

    /// Counts the call and writes ``data`` to the destination.
    ///
    /// - Parameters:
    ///   - url: Requested artifact URL; ignored by the fixture.
    ///   - destination: File that receives the fixture bytes.
    /// - Throws: When the fixture bytes cannot be written.
    func download(from url: URL, to destination: URL) async throws {
        counter.increment()
        try data.write(to: destination)
    }
}

/// Suspends until the surrounding task is cancelled.
///
/// Used to assert that a cancelled provisioning run never publishes a Runtime.
struct CancellableDownloader: RuntimeAssetDownloading {
    /// Suspends in a loop, letting cancellation unwind the caller.
    ///
    /// - Parameters:
    ///   - url: Requested artifact URL; unused.
    ///   - destination: Destination the double never writes to.
    /// - Throws: `CancellationError` when the sleeping task is cancelled.
    func download(from url: URL, to destination: URL) async throws {
        try Task.checkCancellation()
        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}

/// Fakes the two setup commands by writing the files a real run would produce.
///
/// `tar` invocations get a fake Node.js binary and npm CLI, and `npm ci` gets the
/// Harness package, the pnpm package, the pnpm shim, and the native `node-pty`
/// files, so the provisioner's validation runs against a complete tree without a
/// network.
final class FixtureCommandRunner: RuntimeCommandRunning, @unchecked Sendable {
    private let fileManager = FileManager.default
    private(set) var invocationCount = 0

    /// Recreates the layout the given command would have produced.
    ///
    /// - Parameters:
    ///   - executable: Command being run; unused.
    ///   - arguments: Arguments used to tell the extraction and install cases apart.
    ///   - currentDirectory: Directory the fixture writes into.
    ///   - environment: Environment for the command; unused.
    /// - Returns: A successful result with empty output.
    /// - Throws: When the fixture files cannot be written.
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
            let packageJSON = "{\"name\":\"@deepseek-ai/dsh\",\"version\":\"\(RuntimeRelease.harnessVersion)\"}"
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
