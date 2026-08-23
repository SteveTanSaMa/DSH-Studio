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

private final class RuntimePipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collectedData = Data()

    func drain(_ handle: FileHandle) {
        let data = handle.readDataToEndOfFile()
        lock.lock()
        collectedData = data
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return collectedData
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
        // Drain both pipes while the process runs. Waiting for exit first can
        // deadlock when a command such as tar -tzf fills its stdout pipe.
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputCollector = RuntimePipeCollector()
        let errorCollector = RuntimePipeCollector()
        let drainGroup = DispatchGroup()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()

        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputCollector.drain(outputPipe.fileHandleForReading)
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errorCollector.drain(errorPipe.fileHandleForReading)
            drainGroup.leave()
        }

        process.waitUntilExit()
        drainGroup.wait()
        return RuntimeCommandResult(
            status: process.terminationStatus,
            stdout: String(data: outputCollector.data(), encoding: .utf8) ?? "",
            stderr: bounded(String(data: errorCollector.data(), encoding: .utf8) ?? "")
        )
    }

    private func bounded(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 100_000 else { return clean }
        return String(clean.prefix(100_000))
    }
}
