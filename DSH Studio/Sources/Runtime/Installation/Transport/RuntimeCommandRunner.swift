//
//  RuntimeCommandRunner.swift
//  DSH Studio
//

import Foundation

/// The outcome of one child command.
public struct RuntimeCommandResult: Sendable {
    /// Process termination status; `0` means success.
    public let status: Int32
    /// Standard output captured for the caller.
    public let stdout: String
    /// Standard error, trimmed and capped at 100 000 characters.
    public let stderr: String

    /// Creates a command result.
    ///
    /// - Parameters:
    ///   - status: Process termination status.
    ///   - stdout: Captured standard output.
    ///   - stderr: Captured standard error.
    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs child commands on behalf of the installer and market manager.
///
/// The seam exists so tests can answer commands without executing them.
public protocol RuntimeCommandRunning: Sendable {
    /// Runs one command and waits for it to exit.
    ///
    /// - Parameters:
    ///   - executable: Command to run.
    ///   - arguments: Arguments passed to the command.
    ///   - currentDirectory: Working directory for the child.
    ///   - environment: Complete environment for the child.
    /// - Returns: The termination status and captured output.
    /// - Throws: When the command cannot be started or its output read.
    func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String]
    ) throws -> RuntimeCommandResult
}

/// The production command runner, backed by Foundation's `Process`.
public struct SystemRuntimeCommandRunner: RuntimeCommandRunning, Sendable {
    /// Creates a runner with no shared state.
    public init() {}

    /// Runs a command and waits for it to exit.
    ///
    /// Output is redirected to temporary files instead of pipes, which keeps the
    /// call blocking only on the child process rather than on utility-QoS drain
    /// queues. Standard error is trimmed and capped before it is returned.
    ///
    /// - Parameters:
    ///   - executable: Command to run.
    ///   - arguments: Arguments passed to the command.
    ///   - currentDirectory: Working directory for the child.
    ///   - environment: Complete environment for the child.
    /// - Returns: The termination status and captured output.
    /// - Throws: An error from `Process` when the command cannot be started or its
    ///   output cannot be read.
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
