//
//  RuntimeManagerTests.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import XCTest
@testable import DeepSeekRuntime
@testable import DeepSeekHarness
@testable import DeepSeekLogging

/// Exercises RuntimeManager lifecycle, restart, provisioning, and cancellation.
final class RuntimeManagerTests: XCTestCase {

    /// A freshly created manager has not started anything.
    @MainActor
    func testInitialStateIsIdle() {
        let manager = makeManager()
        XCTAssertEqual(manager.state, .idle)
    }

    /// The ready line from the child moves the manager to ready and exposes its URL.
    @MainActor
    func testSuccessfulLaunchReachesReady() async {
        let fake = FakeHarnessProcess()
        let manager = makeManager(process: fake, healthResult: true)
        manager.start()
        fake.emitOutput("dsh web: http://127.0.0.1:43210\n")
        let ready = await waitUntil(manager.state == .ready)
        XCTAssertTrue(ready)
        XCTAssertEqual(manager.readyURL?.absoluteString, "http://127.0.0.1:43210")
    }

    /// The printed process token survives into ``RuntimeManager/readyURL``.
    ///
    /// The WebView needs the token to authenticate its first request.
    @MainActor
    func testSuccessfulLaunchPreservesHarnessProcessTokenForWebView() async {
        let fake = FakeHarnessProcess()
        let manager = makeManager(process: fake, healthResult: true)
        manager.start()
        fake.emitOutput("dsh web: http://127.0.0.1:43210/?token=process-secret\n")

        let ready = await waitUntil(manager.state == .ready)
        XCTAssertTrue(ready)
        XCTAssertEqual(
            manager.readyURL?.absoluteString,
            "http://127.0.0.1:43210/?token=process-secret"
        )
        XCTAssertFalse(manager.logs.entries.contains { $0.message.contains("process-secret") })
    }

    /// A child that becomes ready but fails its health check ends in the failed state.
    @MainActor
    func testFailedHealthCheckFails() async {
        let fake = FakeHarnessProcess()
        let manager = makeManager(process: fake, healthResult: false)
        manager.start()
        fake.emitOutput("dsh web: http://127.0.0.1:43211\n")
        let failed = await waitUntil(manager.state == .failed)
        XCTAssertTrue(failed)
    }

    /// A child that never prints the ready line fails once the startup timeout elapses.
    @MainActor
    func testStartupTimeoutFails() async {
        let fake = FakeHarnessProcess()
        let manager = makeManager(process: fake, startupTimeout: 0.05)
        manager.start()
        let failed = await waitUntil(manager.state == .failed, timeout: 1)
        XCTAssertTrue(failed)
        guard case .readyTimeout = manager.lastError else {
            XCTFail("expected ready timeout, got \(String(describing: manager.lastError))")
            return
        }
    }

    /// An unexpected exit after readiness is reported as a crash, not a stop.
    @MainActor
    func testProcessCrashAfterReady() async {
        let fake = FakeHarnessProcess()
        let manager = makeManager(process: fake, healthResult: true, restartPolicy: RestartPolicy(enabled: false))
        manager.start()
        XCTAssertEqual(manager.currentProcessGeneration, 1)
        fake.emitOutput("dsh web: http://127.0.0.1:43212\n")
        _ = await waitUntil(manager.state == .ready)
        fake.simulateTermination(1)
        let crashed = await waitUntil(manager.state == .crashed)
        XCTAssertTrue(crashed)
        XCTAssertEqual(manager.lastTerminationStatus, 1)
    }

    /// Crash output is redacted before it reaches the log store.
    @MainActor
    func testCrashLogsRedactSecrets() async {
        let fake = FakeHarnessProcess()
        let manager = makeManager(process: fake, healthResult: true, restartPolicy: RestartPolicy(enabled: false))
        manager.start()
        fake.emitError("apiKey=sk-secret123 Authorization: Bearer abc.def\n")
        _ = await waitUntil(manager.logs.entries.contains { $0.message.contains("<redacted>") })
        fake.simulateTermination(1)

        _ = await waitUntil(manager.state == .crashed)
        guard case .processCrashed(_, let stderr) = manager.lastError else {
            XCTFail("expected process crash error")
            return
        }
        let redactedStderr = stderr.joined(separator: "\n")
        XCTAssertFalse(redactedStderr.contains("sk-secret123"))
        XCTAssertFalse(redactedStderr.contains("abc.def"))
        XCTAssertTrue(redactedStderr.contains("<redacted>"))
    }

    /// The restart policy brings Harness back after an unexpected exit.
    @MainActor
    func testAutomaticRestartAfterUnexpectedCrash() async {
        let fake = FakeHarnessProcess()
        let manager = makeManager(
            process: fake,
            healthResult: true,
            restartPolicy: RestartPolicy(maxAttempts: 3, delays: [0.01, 0.01, 0.01])
        )
        manager.start()
        fake.emitOutput("dsh web: http://127.0.0.1:43214\n")
        _ = await waitUntil(manager.state == .ready)
        fake.simulateTermination(1)
        _ = await waitUntil(manager.state == .starting)
        XCTAssertEqual(manager.restartCount, 1)
        XCTAssertEqual(manager.currentProcessGeneration, 2)
        fake.emitOutput("dsh web: http://127.0.0.1:43215\n")
        _ = await waitUntil(manager.state == .ready)
    }

    /// An intentional restart stops and starts without entering the crash path.
    @MainActor
    func testIntentionalRestartUsesNormalLifecycle() async {
        let first = FakeHarnessProcess()
        let second = FakeHarnessProcess()
        let manager = RuntimeManager(
            configuration: testConfiguration(gracefulTimeout: 0.05),
            processFactory: SequencedProcessFactory(processes: [first, second]),
            healthChecker: FakeHealthChecker(result: true),
            restartPolicy: RestartPolicy(enabled: false),
            validateRuntimeOnStart: false
        )

        manager.start()
        first.emitOutput("dsh web: http://127.0.0.1:43216\n")
        let initiallyReady = await waitUntil(manager.state == .ready)
        XCTAssertTrue(initiallyReady)

        let restarted = await manager.restart()
        XCTAssertTrue(restarted)
        XCTAssertEqual(manager.state, .starting)
        XCTAssertEqual(manager.lastTerminationStatus, nil)

        second.emitOutput("dsh web: http://127.0.0.1:43217\n")
        let finallyReady = await waitUntil(manager.state == .ready)
        XCTAssertTrue(finallyReady)
        XCTAssertEqual(manager.lastError, nil)
    }

    /// A termination callback from a superseded process cannot change the new state.
    @MainActor
    func testLateTerminationFromPreviousProcessIsIgnored() async {
        let first = FakeHarnessProcess()
        let second = FakeHarnessProcess()
        let factory = SequencedProcessFactory(processes: [first, second])
        let manager = RuntimeManager(
            configuration: testConfiguration(),
            processFactory: factory,
            healthChecker: FakeHealthChecker(result: true),
            restartPolicy: RestartPolicy(maxAttempts: 1, delays: [0.01]),
            validateRuntimeOnStart: false
        )

        manager.start()
        first.emitOutput("dsh web: http://127.0.0.1:43218\n")
        _ = await waitUntil(manager.state == .ready)
        first.simulateTermination(1)
        _ = await waitUntil(manager.state == .starting)

        first.emitLateTermination(9)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(manager.state, .starting)

        second.emitOutput("dsh web: http://127.0.0.1:43219\n")
        let ready = await waitUntil(manager.state == .ready)
        XCTAssertTrue(ready)
    }

    /// A health result belonging to a previous generation cannot mark the new one ready.
    @MainActor
    func testLateHealthCheckFromPreviousProcessCannotReadyNewProcess() async {
        let first = FakeHarnessProcess()
        let second = FakeHarnessProcess()
        let health = SequencedHealthChecker()
        let manager = RuntimeManager(
            configuration: testConfiguration(startupTimeout: 5),
            processFactory: SequencedProcessFactory(processes: [first, second]),
            healthChecker: health,
            restartPolicy: RestartPolicy(maxAttempts: 1, delays: [0.01]),
            validateRuntimeOnStart: false
        )

        manager.start()
        first.emitOutput("dsh web: http://127.0.0.1:43221\n")
        let firstHealthStarted = await waitUntil(health.callCount == 1)
        XCTAssertTrue(firstHealthStarted)

        first.simulateTermination(1)
        let restarting = await waitUntil(second.launchCount == 1)
        XCTAssertTrue(restarting)
        second.emitOutput("dsh web: http://127.0.0.1:43222\n")
        let secondHealthStarted = await waitUntil(health.callCount == 2)
        XCTAssertTrue(secondHealthStarted)

        health.resolve(index: 0, result: true)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(manager.state, .starting)

        health.resolve(index: 1, result: true)
        let ready = await waitUntil(manager.state == .ready)
        XCTAssertTrue(ready)
        XCTAssertEqual(manager.readyURL?.port, 43222)
    }

    /// Builds a manager wired to the fakes, with validation disabled.
    ///
    /// - Parameters:
    ///   - process: Process double the manager launches.
    ///   - healthResult: Answer returned by the health checker.
    ///   - startupTimeout: Seconds allowed before a launch is failed.
    ///   - gracefulTimeout: Seconds allowed for a graceful stop.
    ///   - restartPolicy: Policy applied to unexpected exits.
    ///   - provisioner: Installer used when the Runtime is missing.
    /// - Returns: A manager configured for tests.
    @MainActor
    func makeManager(
        process: FakeHarnessProcess = FakeHarnessProcess(),
        healthResult: Bool = true,
        startupTimeout: TimeInterval = 0.5,
        gracefulTimeout: TimeInterval = 0.5,
        restartPolicy: RestartPolicy = RestartPolicy(),
        provisioner: (any RuntimeProvisioning)? = nil
    ) -> RuntimeManager {
        let factory = FakeProcessFactory(process: process)
        let health = FakeHealthChecker(result: healthResult)
        return RuntimeManager(
            configuration: testConfiguration(
                startupTimeout: startupTimeout,
                gracefulTimeout: gracefulTimeout
            ),
            processFactory: factory,
            healthChecker: health,
            restartPolicy: restartPolicy,
            validateRuntimeOnStart: false,
            provisioner: provisioner
        )
    }

    /// Builds a launch configuration rooted in temporary-looking paths.
    ///
    /// - Parameters:
    ///   - startupTimeout: Seconds allowed before a launch is failed.
    ///   - gracefulTimeout: Seconds allowed for a graceful stop.
    /// - Returns: A configuration that never touches the real Runtime.
    @MainActor
    func testConfiguration(
        startupTimeout: TimeInterval = 0.5,
        gracefulTimeout: TimeInterval = 0.5
    ) -> RuntimeConfiguration {
        RuntimeConfiguration(
            nodeExecutable: URL(fileURLWithPath: "/tmp/node"),
            harnessEntry: URL(fileURLWithPath: "/tmp/bin.js"),
            dshHome: URL(fileURLWithPath: "/tmp/dsh-home"),
            workspace: URL(fileURLWithPath: "/tmp/workspace"),
            startupTimeout: startupTimeout,
            gracefulTimeout: gracefulTimeout
        )
    }

    /// Polls a condition until it holds or the timeout expires.
    ///
    /// - Parameters:
    ///   - condition: Condition to poll on the main actor.
    ///   - timeout: Seconds to keep polling.
    /// - Returns: The condition's value at the last check.
    @MainActor
    func waitUntil(
        _ condition: @autoclosure @escaping () -> Bool,
        timeout: TimeInterval = 1
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}
