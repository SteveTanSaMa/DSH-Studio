//
//  RuntimeManagerTestDoubles.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import Foundation
@testable import DeepSeekHarness
@testable import DeepSeekRuntime

/// In-memory process double used to drive lifecycle callbacks deterministically.
final class FakeHarnessProcess: HarnessProcess {
    /// A stable identifier so PID assertions do not depend on the host.
    var pid: Int32? { 123 }
    /// Whether the double has not been terminated yet.
    var isRunning: Bool { !terminated }
    /// Callback the manager installs for standard output.
    var onOutput: ((Data) -> Void)?
    /// Callback the manager installs for standard error.
    var onError: ((Data) -> Void)?
    /// Callback the manager installs for process exit.
    var onTermination: ((Int32) -> Void)?
    /// When set, a graceful termination is recorded but never exits.
    ///
    /// This is what drives the graceful-timeout path.
    var ignoreGracefulTermination = false
    /// Number of graceful termination requests received.
    var gracefulCount = 0
    /// Number of forced terminations received.
    var forceCount = 0
    /// Number of launches performed.
    var launchCount = 0
    private var terminated = false

    /// Marks the double running and records the launch.
    func launch() throws {
        terminated = false
        launchCount += 1
    }

    /// Feeds stdout to the same callback used by `Process`.
    func emitOutput(_ string: String) {
        onOutput?(Data(string.utf8))
    }

    /// Feeds stderr to the same callback used by `Process`.
    func emitError(_ string: String) {
        onError?(Data(string.utf8))
    }

    /// Simulates a delayed callback from a process instance that was replaced.
    func emitLateTermination(_ status: Int32) {
        onTermination?(status)
    }

    /// Records a graceful termination and exits unless it is being ignored.
    func terminateGracefully() {
        gracefulCount += 1
        guard !ignoreGracefulTermination else { return }
        simulateTermination(0)
    }

    /// Records a forced termination and reports a `SIGKILL` exit.
    func forceTerminate() {
        forceCount += 1
        simulateTermination(9)
    }

    /// Reports an exit once, ignoring repeated calls.
    ///
    /// - Parameter status: Exit status delivered to the termination callback.
    func simulateTermination(_ status: Int32) {
        guard !terminated else { return }
        terminated = true
        onTermination?(status)
    }
}

/// Returns one fixed process for tests that do not exercise replacement.
final class FakeProcessFactory: HarnessProcessFactory {
    /// The process handed to every caller.
    let process: FakeHarnessProcess

    /// Creates a factory that always returns one process.
    ///
    /// - Parameter process: Process to return.
    init(process: FakeHarnessProcess) {
        self.process = process
    }

    /// Installs the callbacks on the fixed process and returns it.
    func makeProcess(
        configuration: RuntimeConfiguration,
        onOutput: @escaping (Data) -> Void,
        onError: @escaping (Data) -> Void,
        onTermination: @escaping (Int32) -> Void
    ) -> HarnessProcess {
        process.onOutput = onOutput
        process.onError = onError
        process.onTermination = onTermination
        return process
    }
}

/// Supplies successive processes so stale callbacks can be tested across restarts.
final class SequencedProcessFactory: HarnessProcessFactory {
    private let processes: [FakeHarnessProcess]
    private var nextIndex = 0

    /// Creates a factory over a fixed sequence of processes.
    ///
    /// - Parameter processes: Processes returned in order.
    init(processes: [FakeHarnessProcess]) {
        self.processes = processes
    }

    /// Returns the next process, repeating the last one when the sequence is spent.
    func makeProcess(
        configuration: RuntimeConfiguration,
        onOutput: @escaping (Data) -> Void,
        onError: @escaping (Data) -> Void,
        onTermination: @escaping (Int32) -> Void
    ) -> HarnessProcess {
        let index = min(nextIndex, processes.count - 1)
        nextIndex += 1
        let process = processes[index]
        process.onOutput = onOutput
        process.onError = onError
        process.onTermination = onTermination
        return process
    }
}

/// Simulates a successful, failed, or cancellable Runtime download.
final class FakeRuntimeProvisioner: RuntimeProvisioning, @unchecked Sendable {
    /// Installation root reported by the fake provisioner.
    let root: URL
    /// Architecture reported by the fake provisioner.
    let architecture = "darwin-arm64"
    private let error: Error?
    private let waitsForCancellation: Bool

    /// Creates a provisioner that succeeds, fails, or waits to be cancelled.
    ///
    /// - Parameters:
    ///   - root: Installation root to report.
    ///   - error: Error to throw instead of installing, when set.
    ///   - waitsForCancellation: When `true`, `provision()` suspends until the task
    ///     is cancelled, which exercises the cancellation path.
    init(
        root: URL,
        error: Error? = nil,
        waitsForCancellation: Bool = false
    ) {
        self.root = root
        self.error = error
        self.waitsForCancellation = waitsForCancellation
    }

    /// Throws the configured error, waits for cancellation, or reports success.
    ///
    /// - Returns: A result carrying the configured root and a manifest built from the
    ///   pinned release.
    /// - Throws: The configured error, or `CancellationError` when the wait is
    ///   cancelled.
    func provision() async throws -> RuntimeProvisioningResult {
        if let error {
            throw error
        }
        if waitsForCancellation {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            throw CancellationError()
        }
        return RuntimeProvisioningResult(
            root: root,
            architecture: architecture,
            manifest: RuntimeInstallationManifest(
                architecture: architecture,
                nodeVersion: RuntimeRelease.nodeVersion,
                harnessVersion: RuntimeRelease.harnessVersion,
                nodeSHA256: RuntimeRelease.nodeArchiveSHA256(architecture: architecture)!,
                harnessPackageIntegrity: RuntimeRelease.harnessPackageIntegrity
            )
        )
    }
}

/// Immediately returns a configured health-check result.
final class FakeHealthChecker: HarnessHealthChecking {
    /// Result returned by every health check.
    let result: Bool

    /// Creates a checker with a fixed answer.
    ///
    /// - Parameter result: Value returned by ``check(baseURL:timeout:)``.
    init(result: Bool) {
        self.result = result
    }

    /// Returns the configured result immediately.
    func check(baseURL: URL, timeout: TimeInterval) async -> Bool {
        result
    }
}

/// Holds health-check continuations until a test explicitly resolves them.
final class SequencedHealthChecker: HarnessHealthChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Bool, Never>] = []

    /// Number of health checks that are currently suspended.
    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }

    /// Suspends until the test resolves this call.
    ///
    /// - Returns: The value passed to ``resolve(index:result:)``.
    func check(baseURL: URL, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            continuations.append(continuation)
            lock.unlock()
        }
    }

    /// Resumes one suspended health check.
    ///
    /// - Parameters:
    ///   - index: Zero-based index of the suspended call.
    ///   - result: Value the call should return.
    func resolve(index: Int, result: Bool) {
        lock.lock()
        guard continuations.indices.contains(index) else {
            lock.unlock()
            return
        }
        let continuation = continuations[index]
        lock.unlock()
        continuation.resume(returning: result)
    }
}
