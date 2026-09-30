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
    /// Byte counts reported through the progress closure before the file is written.
    var reportedProgress: [(received: Int64, expected: Int64)] = []
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

    /// Reports the configured byte steps, then writes the fixture bytes.
    ///
    /// - Parameters:
    ///   - url: Requested artifact URL; ignored by the fixture.
    ///   - destination: File that receives the fixture bytes.
    ///   - onProgress: Receives each configured byte count.
    /// - Throws: When the fixture bytes cannot be written.
    func download(
        from url: URL,
        to destination: URL,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws {
        for step in reportedProgress {
            onProgress?(step.received, step.expected)
        }
        try await download(from: url, to: destination)
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

/// Fakes the setup commands by writing the files a real run would produce.
///
/// `tar` invocations get a fake Node.js binary and npm CLI, and `npm ci` gets the
/// Harness package, the pnpm package, the pnpm shim, and the native `node-pty`
/// files, so the provisioner's validation runs against a complete tree without a
/// network. When the fixture includes the native module the Harness session
/// persistence loads, `npm rebuild` produces its binding and the packaged Node's
/// module probe is answered by the double.
final class FixtureCommandRunner: RuntimeCommandRunning, @unchecked Sendable {
    private let fileManager = FileManager.default
    private(set) var invocationCount = 0
    /// Whether the installed Harness tree contains the native module that has to be
    /// compiled locally, as the current Harness line does for `fs-ext`.
    let includesNativeBinding: Bool
    /// Whether the packaged Node's module probe fails, which must fail the install.
    let nativeBindingFailsToLoad: Bool

    /// Creates the fixture runner.
    ///
    /// - Parameters:
    ///   - includesNativeBinding: Install an `fs-ext` package during `npm ci`.
    ///   - nativeBindingFailsToLoad: Answer the packaged Node's module probe with a
    ///     load failure.
    init(includesNativeBinding: Bool = false, nativeBindingFailsToLoad: Bool = false) {
        self.includesNativeBinding = includesNativeBinding
        self.nativeBindingFailsToLoad = nativeBindingFailsToLoad
    }

    /// Recreates the layout the given command would have produced.
    ///
    /// - Parameters:
    ///   - executable: Command being run; unused.
    ///   - arguments: Arguments used to tell the extraction, install, rebuild, and
    ///     module-probe cases apart.
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
        if arguments.first == "-e" {
            // The packaged Node's module probe. A fixture Node cannot really load a
            // binding, so the double answers for it.
            return nativeBindingFailsToLoad
                ? RuntimeCommandResult(status: 1, stdout: "", stderr: "dlopen(fs_ext.node) failed\n")
                : RuntimeCommandResult(status: 0, stdout: "", stderr: "")
        }
        if arguments.contains("rebuild") {
            // `npm rebuild fs-ext` compiles the binding and leaves build material the
            // install is expected to prune.
            try writeNativeBinding(in: currentDirectory)
        } else if arguments.first == "-xzf",
                  let index = arguments.firstIndex(of: "-C"),
                  arguments.indices.contains(index + 1) {
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

            if includesNativeBinding {
                // The package ships no binding, exactly like the real one, so the
                // install has to compile it.
                let module = currentDirectory.appendingPathComponent("node_modules/fs-ext", isDirectory: true)
                try fileManager.createDirectory(at: module, withIntermediateDirectories: true)
                try Data("{\"name\":\"fs-ext\",\"version\":\"2.1.1\"}".utf8)
                    .write(to: module.appendingPathComponent("package.json"))
            }
        }
        return RuntimeCommandResult(status: 0, stdout: "", stderr: "")
    }

    /// Writes the binding a completed `npm rebuild` produces, plus the material it
    /// leaves behind.
    ///
    /// - Parameter harnessRoot: Harness root the rebuild ran in.
    /// - Throws: When a fixture file cannot be written.
    private func writeNativeBinding(in harnessRoot: URL) throws {
        let build = harnessRoot.appendingPathComponent("node_modules/fs-ext/build", isDirectory: true)
        let release = build.appendingPathComponent("Release", isDirectory: true)
        try fileManager.createDirectory(at: release, withIntermediateDirectories: true)
        try Data("fixture binding".utf8).write(to: release.appendingPathComponent("fs_ext.node"))
        try Data("object".utf8).write(to: release.appendingPathComponent("fs_ext.o"))
        try Data("dependency".utf8).write(to: release.appendingPathComponent("fs_ext.d"))

        let objects = build.appendingPathComponent("obj.target/fs-ext/src", isDirectory: true)
        try fileManager.createDirectory(at: objects, withIntermediateDirectories: true)
        try Data("object".utf8).write(to: objects.appendingPathComponent("fs-ext.o"))
        try Data("all:\n".utf8).write(to: build.appendingPathComponent("Makefile"))
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
