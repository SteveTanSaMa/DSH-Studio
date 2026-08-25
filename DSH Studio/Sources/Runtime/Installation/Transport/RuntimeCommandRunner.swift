//
//  RuntimeCommandRunner.swift
//  DSH Studio
//

import Foundation

public struct RuntimeCommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol RuntimeCommandRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String]
    ) throws -> RuntimeCommandResult
}

public struct SystemRuntimeCommandRunner: RuntimeCommandRunning, Sendable {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String]
    ) throws -> RuntimeCommandResult {
        // Redirect directly to temporary files so the caller only waits for the
        // child process. Waiting on utility-QoS pipe-draining queues from a
        // user-initiated task creates a priority inversion.
        let fileManager = FileManager.default
        let outputDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("DSHStudio-RuntimeCommand-\(UUID().uuidString)", isDirectory: true)
        let outputURL = outputDirectory.appendingPathComponent("stdout", isDirectory: false)
        let errorURL = outputDirectory.appendingPathComponent("stderr", isDirectory: false)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: outputDirectory)
        }

        try Data().write(to: outputURL, options: .atomic)
        try Data().write(to: errorURL, options: .atomic)
        var outputHandle: FileHandle?
        var errorHandle: FileHandle?
        defer {
            try? outputHandle?.close()
            try? errorHandle?.close()
        }

        outputHandle = try FileHandle(forWritingTo: outputURL)
        errorHandle = try FileHandle(forWritingTo: errorURL)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = environment
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        try process.run()
        process.waitUntilExit()

        try outputHandle?.close()
        outputHandle = nil
        try errorHandle?.close()
        errorHandle = nil
        return RuntimeCommandResult(
            status: process.terminationStatus,
            stdout: String(data: try Data(contentsOf: outputURL), encoding: .utf8) ?? "",
            stderr: bounded(String(data: try Data(contentsOf: errorURL), encoding: .utf8) ?? "")
        )
    }

    private func bounded(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 100_000 else { return clean }
        return String(clean.prefix(100_000))
    }
}
