//
//  RuntimeManager.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import Combine
import Darwin
import Foundation
import DeepSeekHarness
import DeepSeekLogging

/// Owns the Harness child process and its lifecycle state machine.
@MainActor
public final class RuntimeManager: ObservableObject {
    @Published public private(set) var state: RuntimeState = .idle
    @Published public private(set) var readyURL: URL?
    @Published public private(set) var lastError: RuntimeError?
    @Published public private(set) var nodeVersion: String?
    @Published public private(set) var harnessVersion: String?
    @Published public private(set) var restartCount = 0

    public private(set) var configuration: RuntimeConfiguration
    public let logs: RuntimeLogStore
    public var restartPolicy: RestartPolicy

    private let processFactory: HarnessProcessFactory
    private let healthChecker: HarnessHealthChecking
    private let provisioner: (any RuntimeProvisioning)?
    private let validateRuntimeOnStart: Bool
    private let restartTracker = RestartTracker()
    private var process: HarnessProcess?
    private var stagedURL: URL?
    private var startupTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var provisioningTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var processGeneration = 0
    private var stopRequested = false
    private var processExited = false
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var lastStderrLines: [String] = []
    private let readyPattern = try! NSRegularExpression(
        pattern: #"dsh web: (http://127\.0\.0\.1:\d+)"#
    )

    public init(
        configuration: RuntimeConfiguration,
        processFactory: HarnessProcessFactory = SystemHarnessProcessFactory(),
        healthChecker: HarnessHealthChecking = SystemHarnessHealthChecker(),
        logFileURL: URL? = nil,
        restartPolicy: RestartPolicy = RestartPolicy(),
        validateRuntimeOnStart: Bool = true,
        provisioner: (any RuntimeProvisioning)? = nil
    ) {
        self.configuration = configuration
        self.processFactory = processFactory
        self.healthChecker = healthChecker
        self.provisioner = provisioner
        self.restartPolicy = restartPolicy
        self.validateRuntimeOnStart = validateRuntimeOnStart
        self.logs = RuntimeLogStore(logFileURL: logFileURL)
        self.nodeVersion = RuntimeLocator.nodeVersion(nodeExecutable: configuration.nodeExecutable)
        self.harnessVersion = RuntimeLocator.packageJSONVersion(at: configuration.harnessEntry)
    }

    public func start() {
        guard state == .idle || state == .failed || state == .crashed || state == .terminated else {
            return
        }
        restartTask?.cancel()
        restartTask = nil
        lastError = nil
        readyURL = nil
        stopRequested = false
        processExited = false
        stdoutBuffer = ""
        stderrBuffer = ""

        if let provisioner,
           !RuntimeLocator.isComplete(
               root: provisioner.root,
               architecture: provisioner.architecture
           ) {
            beginProvisioning(with: provisioner)
            return
        }
        beginLaunch()
    }

    private func beginProvisioning(with provisioner: any RuntimeProvisioning) {
        state = .provisioning
        logs.log(component: "Runtime", level: "info", message: "preparing online Runtime")
        provisioningTask?.cancel()
        provisioningTask = Task.detached { [weak self, provisioner] in
            do {
                let result = try await provisioner.provision()
                guard !Task.isCancelled else { return }
                await self?.finishProvisioning(result)
            } catch is CancellationError {
                return
            } catch {
                await self?.failProvisioning(error)
            }
        }
    }

    private func finishProvisioning(_ result: RuntimeProvisioningResult) {
        guard state == .provisioning else { return }
        configuration.nodeExecutable = RuntimeLocator.nodeExecutable(
            root: result.root,
            architecture: result.architecture
        )
        configuration.harnessEntry = RuntimeLocator.harnessEntry(
            root: result.root,
            architecture: result.architecture
        )
        refreshRuntimeVersions()
        provisioningTask = nil
        beginLaunch()
    }

    private func failProvisioning(_ error: Error) {
        guard state == .provisioning else { return }
        provisioningTask = nil
        fail(.runtimeProvisioningFailed(error.localizedDescription))
    }

    private func beginLaunch() {
        state = .launching
        processGeneration += 1
        let generation = processGeneration

        logs.log(component: "App", level: "info", message: "app launch")
        logs.log(component: "Runtime", level: "info", message: "node path \(configuration.nodeExecutable.path)")
        logs.log(component: "Runtime", level: "info", message: "node version \(nodeVersion ?? "unknown")")
        logs.log(component: "Runtime", level: "info", message: "harness version \(harnessVersion ?? "unknown")")

        if validateRuntimeOnStart {
            guard validateRuntime() else { return }
        }
        guard prepareDirectories() else { return }
        cleanStaleProcessIfNeeded()

        let process = processFactory.makeProcess(
            configuration: configuration,
            onOutput: { [weak self] data in
                Task { @MainActor [weak self] in
                    self?.handleStdout(data, generation: generation)
                }
            },
            onError: { [weak self] data in
                Task { @MainActor [weak self] in
                    self?.handleStderr(data, generation: generation)
                }
            },
            onTermination: { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.handleTermination(status, generation: generation)
                }
            }
        )
        self.process = process

        do {
            try process.launch()
        } catch {
            self.process = nil
            fail(.processLaunchFailed(error.localizedDescription))
            return
        }

        logs.log(component: "Runtime", level: "info", message: "process launch pid \(process.pid.map(String.init) ?? "unknown")")
        if let pid = process.pid {
            let pidURL = configuration.dshHome
                .deletingLastPathComponent()
                .appendingPathComponent("runtime.pid")
            try? String(pid).data(using: .utf8)?.write(to: pidURL)
        }
        state = .starting
        armStartupTimeout(generation: generation)
    }

    private func refreshRuntimeVersions() {
        nodeVersion = RuntimeLocator.nodeVersion(nodeExecutable: configuration.nodeExecutable)
        harnessVersion = RuntimeLocator.packageJSONVersion(at: configuration.harnessEntry)
    }

    public func retry() {
        guard state == .failed || state == .crashed else { return }
        restartTracker.reset()
        restartCount = 0
        start()
    }

    public func updateStartupTimeout(_ timeout: TimeInterval) {
        configuration.startupTimeout = timeout
    }

    public func stop() async {
        if state == .terminated || state == .idle {
            return
        }
        if state == .provisioning {
            stopRequested = true
            restartTask?.cancel()
            restartTask = nil
            provisioningTask?.cancel()
            provisioningTask = nil
            readyURL = nil
            state = .terminated
            return
        }
        if let stopTask {
            await stopTask.value
            return
        }
        let task = Task { [weak self] in
            _ = await self?.performStop()
        }
        stopTask = task
        await task.value
    }

    public func forceStop() {
        guard state != .terminated else { return }
        stopRequested = true
        restartTask?.cancel()
        restartTask = nil
        startupTask?.cancel()
        startupTask = nil
        provisioningTask?.cancel()
        provisioningTask = nil
        process?.forceTerminate()
        process = nil
        processExited = true
        readyURL = nil
        state = .terminated
        removePIDFile()
    }

    private func performStop() async {
        defer { stopTask = nil }
        stopRequested = true
        restartTask?.cancel()
        restartTask = nil
        startupTask?.cancel()
        startupTask = nil
        guard let process, state != .terminated else {
            state = .terminated
            self.process = nil
            processExited = true
            readyURL = nil
            removePIDFile()
            return
        }
        state = .stopping
        logs.log(component: "Runtime", level: "info", message: "sending SIGTERM")
        process.terminateGracefully()

        let timeout = UInt64(configuration.gracefulTimeout * 1_000_000_000)
        try? await Task.sleep(nanoseconds: timeout)

        if !processExited {
            logs.log(component: "Runtime", level: "warn", message: "graceful timeout, forcing terminate")
            process.forceTerminate()
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        state = .terminated
        self.process = nil
        removePIDFile()
    }

    private func validateRuntime() -> Bool {
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

    private func prepareDirectories() -> Bool {
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

    private func cleanStaleProcessIfNeeded() {
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

    private func removePIDFile() {
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

    private func handleStdout(_ data: Data, generation: Int) {
        guard generation == processGeneration else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }
        stdoutBuffer += text
        for line in lines(from: &stdoutBuffer) {
            if line.contains("dsh web: http://") {
                logs.log(component: "Harness", level: "info", message: line)
                if let url = parseReadyURL(line) {
                    stagedURL = url
                    Task { [weak self] in
                        await self?.performHealthCheck(url: url, generation: generation)
                    }
                }
            }
        }
    }

    private func handleStderr(_ data: Data, generation: Int) {
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

    private func performHealthCheck(url: URL, generation: Int) async {
        guard state == .starting, generation == processGeneration else { return }
        logs.log(component: "Harness", level: "info", message: "detected port \(url.port.map(String.init) ?? "unknown")")
        logs.log(component: "Harness", level: "info", message: "health check \(url.appendingPathComponent("api/host.describe").absoluteString)")
        // A late response from an old process must not mark its replacement
        // ready, so the generation is checked again after this await.
        let healthy = await healthChecker.check(
            baseURL: url,
            timeout: configuration.healthCheckTimeout
        )
        guard state == .starting, generation == processGeneration else { return }
        if healthy {
            startupTask?.cancel()
            startupTask = nil
            restartTracker.reset()
            restartCount = 0
            readyURL = url
            state = .ready
            logs.log(component: "Harness", level: "info", message: "health check ok")
            logs.log(component: "Runtime", level: "info", message: "state ready")
        } else {
            fail(.healthCheckFailed)
        }
    }

    private func handleTermination(_ status: Int32, generation: Int) {
        guard generation == processGeneration else { return }
        processExited = true
        process = nil
        logs.log(component: "Runtime", level: "info", message: "runtime termination status \(status)")
        if state == .failed { return }
        if stopRequested {
            state = .terminated
            return
        }
        startupTask?.cancel()
        startupTask = nil
        let shouldRestart = state == .ready || state == .starting || state == .launching
        state = shouldRestart ? .crashed : .failed
        lastError = .processCrashed(exitStatus: status, stderr: lastStderrLines)
        if shouldRestart {
            scheduleRestart()
        }
    }

    private func scheduleRestart() {
        guard restartPolicy.enabled else { return }
        let attempt = restartTracker.recordCrash()
        guard let delay = restartPolicy.delay(forAttempt: attempt) else {
            restartCount = restartTracker.attempts
            state = .failed
            logs.log(component: "Runtime", level: "error", message: "restart limit reached")
            return
        }
        restartCount = attempt
        logs.log(component: "Runtime", level: "warn", message: "scheduling restart in \(delay)s (attempt \(attempt))")
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled,
                  let self,
                  self.state == .crashed else { return }
            self.restartTask = nil
            self.start()
        }
    }

    private func armStartupTimeout(generation: Int) {
        let timeout = configuration.startupTimeout
        startupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self,
                  self.processGeneration == generation,
                  self.state == .starting || self.state == .launching else { return }
            self.fail(.readyTimeout(timeout))
        }
    }

    private func fail(_ error: RuntimeError) {
        startupTask?.cancel()
        startupTask = nil
        lastError = error
        logs.log(component: "Runtime", level: "error", message: error.localizedDescription)
        if let process, process.isRunning {
            process.forceTerminate()
        }
        state = .failed
    }
}
