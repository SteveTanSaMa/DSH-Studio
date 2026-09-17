//
//  RuntimeManager+Process.swift
//  DSH Studio
//

import Darwin
import DeepSeekLogging
import Foundation

/// Launch prerequisites and child-process I/O for the manager.
extension RuntimeManager {
    /// Checks that the configured Node.js and Harness paths are usable.
    ///
    /// A missing path fails the manager with ``RuntimeError/missingRuntime(_:)``, so the
    /// UI reports the problem instead of launching a process that cannot work.
    ///
    /// - Returns: `true` when both paths exist and the architecture matches.
    func validateRuntime() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: configuration.nodeExecutable.path) else {
            fail(.missingRuntime(configuration.nodeExecutable.path))
            return false
        }
        guard FileManager.default.fileExists(atPath: configuration.harnessEntry.path) else {
            fail(.missingRuntime(configuration.harnessEntry.path))
            return false
        }
        let expectedArch = RuntimeLocator.architectureDirectory() == "darwin-arm64" ? "arm64" : "x86_64"
        if !RuntimeLocator.architectures(of: configuration.nodeExecutable).contains(expectedArch) {
            fail(.invalidRuntime("Node architecture is not \(expectedArch)"))
            return false
        }
        if let nodeVersion, nodeVersion != configuration.expectedNodeVersion {
            fail(.nodeVersionMismatch(
                expected: configuration.expectedNodeVersion,
                actual: nodeVersion
            ))
            return false
        }
        if let harnessVersion, harnessVersion != configuration.expectedHarnessVersion {
            fail(.harnessVersionMismatch(
                expected: configuration.expectedHarnessVersion,
                actual: harnessVersion
            ))
            return false
        }
        return true
    }

    /// Creates the data home and workspace directories the launch needs.
    ///
    /// - Returns: `true` when every directory exists afterwards.
    func prepareDirectories() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: configuration.dshHome,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: configuration.workspace,
                withIntermediateDirectories: true
            )
            return true
        } catch {
            fail(.dshHomeFailure(error.localizedDescription))
            return false
        }
    }

    /// Terminates a Harness process left behind by a previous run.
    ///
    /// The PID file is only trusted when it names a live process that is not this app,
    /// so a recycled identifier cannot make the manager kill an unrelated process.
    func cleanStaleProcessIfNeeded() {
        let pidURL = configuration.dshHome
            .deletingLastPathComponent()
            .appendingPathComponent("runtime.pid")
        guard let data = try? Data(contentsOf: pidURL),
              let pid = Int32(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
              pid > 0,
              pid != getpid() else { return }
        let output = shell("ps -p \(pid) -o command=")
        guard output.contains(configuration.nodeExecutable.path),
              output.contains(configuration.dshHome.path) else { return }
        logs.log(component: "Runtime", level: "warn", message: "terminating stale runtime pid \(pid)")
        kill(pid, SIGTERM)
        usleep(500_000)
    }

    /// Removes the recorded PID file, ignoring a missing file.
    func removePIDFile() {
        let pidURL = configuration.dshHome
            .deletingLastPathComponent()
            .appendingPathComponent("runtime.pid")
        try? FileManager.default.removeItem(at: pidURL)
    }

    private func shell(_ command: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Buffers child output and reacts to complete lines.
    ///
    /// Output from a superseded process generation is dropped, which is what keeps a
    /// late callback from an old process out of the current state machine.
    ///
    /// - Parameters:
    ///   - data: Chunk read from the child's standard output.
    ///   - generation: Process generation the chunk belongs to.
    func handleStdout(_ data: Data, generation: Int) {
        guard generation == processGeneration else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }
        stdoutBuffer += text
        for line in lines(from: &stdoutBuffer) {
            if line.contains("dsh web: http://") {
                logs.log(
                    component: "Harness",
                    level: "info",
                    message: LogRedactor.redact(line)
                )
                if let url = parseReadyURL(line) {
                    stagedURL = url
                    Task { [weak self] in
                        await self?.performHealthCheck(url: url, generation: generation)
                    }
                }
            }
        }
    }

    /// Buffers child error output and keeps the recent lines for diagnostics.
    ///
    /// - Parameters:
    ///   - data: Chunk read from the child's standard error.
    ///   - generation: Process generation the chunk belongs to.
    func handleStderr(_ data: Data, generation: Int) {
        guard generation == processGeneration else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }
        stderrBuffer += text
        for line in lines(from: &stderrBuffer) {
            lastStderrLines.append(LogRedactor.redact(line))
            if lastStderrLines.count > 80 {
                lastStderrLines.removeFirst(lastStderrLines.count - 80)
            }
            logs.log(component: "Harness", level: "stderr", message: line)
        }
    }

    private func lines(from buffer: inout String) -> [String] {
        var result: [String] = []
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { result.append(line) }
        }
        return result
    }

    private func parseReadyURL(_ line: String) -> URL? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = readyPattern.firstMatch(in: line, range: range),
              let stringRange = Range(match.range(at: 1), in: line),
              let url = URL(string: String(line[stringRange])),
              url.scheme == "http",
              url.host == "127.0.0.1",
              url.port != nil else {
            return nil
        }
        return url
    }
}
