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
    var pid: Int32? { 123 }
    var isRunning: Bool { !terminated }
    var onOutput: ((Data) -> Void)?
    var onError: ((Data) -> Void)?
    var onTermination: ((Int32) -> Void)?
    var ignoreGracefulTermination = false
    var gracefulCount = 0
    var forceCount = 0
    var launchCount = 0
    private var terminated = false

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

    func terminateGracefully() {
        gracefulCount += 1
        guard !ignoreGracefulTermination else { return }
        simulateTermination(0)
    }

    func forceTerminate() {
        forceCount += 1
        simulateTermination(9)
    }

    func simulateTermination(_ status: Int32) {
        guard !terminated else { return }
        terminated = true
        onTermination?(status)
    }
}

/// Returns one fixed process for tests that do not exercise replacement.
final class FakeProcessFactory: HarnessProcessFactory {
    let process: FakeHarnessProcess

    init(process: FakeHarnessProcess) {
        self.process = process
    }

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

    init(processes: [FakeHarnessProcess]) {
        self.processes = processes
    }

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
    let root: URL
    let architecture = "darwin-arm64"
    private let error: Error?
    private let waitsForCancellation: Bool

    init(
        root: URL,
        error: Error? = nil,
        waitsForCancellation: Bool = false
    ) {
        self.root = root
        self.error = error
        self.waitsForCancellation = waitsForCancellation
    }

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
    let result: Bool

    init(result: Bool) {
        self.result = result
    }

    func check(baseURL: URL, timeout: TimeInterval) async -> Bool {
        result
    }
}

/// Holds health-check continuations until a test explicitly resolves them.
final class SequencedHealthChecker: HarnessHealthChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Bool, Never>] = []

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }

    func check(baseURL: URL, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            continuations.append(continuation)
            lock.unlock()
        }
    }

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
