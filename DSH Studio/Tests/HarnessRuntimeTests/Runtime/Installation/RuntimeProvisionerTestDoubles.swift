import Foundation
import XCTest
@testable import DeepSeekRuntime

struct FixtureDownloader: RuntimeAssetDownloading {
    let data: Data
    private let counter = Counter()

    var downloadCount: Int { counter.value }

    func download(from url: URL, to destination: URL) async throws {
        counter.increment()
        try data.write(to: destination)
    }
}

struct CancellableDownloader: RuntimeAssetDownloading {
    func download(from url: URL, to destination: URL) async throws {
        try Task.checkCancellation()
        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}

final class FixtureCommandRunner: RuntimeCommandRunning, @unchecked Sendable {
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
