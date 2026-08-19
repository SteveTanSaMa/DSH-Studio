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
    @MainActor
    func testInitialStateIsIdle() {
        let manager = makeManager()
        XCTAssertEqual(manager.state, .idle)
    }

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

    @MainActor
    func testFailedHealthCheckFails() async {
        let fake = FakeHarnessProcess()
        let manager = makeManager(process: fake, healthResult: false)
        manager.start()
        fake.emitOutput("dsh web: http://127.0.0.1:43211\n")
        let failed = await waitUntil(manager.state == .failed)
        XCTAssertTrue(failed)
    }

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

    @MainActor
    func testProcessCrashAfterReady() async {
        let fake = FakeHarnessProcess()
        let manager = makeManager(process: fake, healthResult: true, restartPolicy: RestartPolicy(enabled: false))
        manager.start()
        fake.emitOutput("dsh web: http://127.0.0.1:43212\n")
        _ = await waitUntil(manager.state == .ready)
        fake.simulateTermination(1)
        let crashed = await waitUntil(manager.state == .crashed)
        XCTAssertTrue(crashed)
    }

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
        fake.emitOutput("dsh web: http://127.0.0.1:43215\n")
        _ = await waitUntil(manager.state == .ready)
    }

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

    @MainActor
    func testAutomaticProvisioningUpdatesConfigurationBeforeLaunch() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-provisioner-\(UUID().uuidString)", isDirectory: true)
        let provisioner = FakeRuntimeProvisioner(root: root)
        let process = FakeHarnessProcess()
        let manager = makeManager(process: process, provisioner: provisioner)

        manager.start()
        XCTAssertEqual(manager.state, .provisioning)
        let starting = await waitUntil(manager.state == .starting)
        XCTAssertTrue(starting)
        XCTAssertEqual(
            manager.configuration.nodeExecutable,
            RuntimeLocator.nodeExecutable(root: root, architecture: "darwin-arm64")
        )
        XCTAssertEqual(
            manager.configuration.harnessEntry,
            RuntimeLocator.harnessEntry(root: root, architecture: "darwin-arm64")
        )

        process.emitOutput("dsh web: http://127.0.0.1:43220\n")
        let ready = await waitUntil(manager.state == .ready)
        XCTAssertTrue(ready)
    }

    @MainActor
    func testProvisioningFailureIsReportedAndDoesNotLaunchProcess() async {
        let process = FakeHarnessProcess()
        let provisioner = FakeRuntimeProvisioner(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("dsh-provisioner-\(UUID().uuidString)", isDirectory: true),
            error: RuntimeProvisioningError.installationFailed("fixture failure")
        )
        let manager = makeManager(process: process, provisioner: provisioner)

        manager.start()
        let failed = await waitUntil(manager.state == .failed)
        XCTAssertTrue(failed)
        guard case .runtimeProvisioningFailed(let detail) = manager.lastError else {
            return XCTFail("expected a provisioning failure, got \(String(describing: manager.lastError))")
        }
        XCTAssertTrue(detail.contains("fixture failure"))
        XCTAssertEqual(process.launchCount, 0)
    }

    @MainActor
    func testStopDuringProvisioningCancelsProvisioningAndStaysTerminated() async {
        let provisioner = FakeRuntimeProvisioner(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("dsh-provisioner-\(UUID().uuidString)", isDirectory: true),
            waitsForCancellation: true
        )
        let manager = makeManager(provisioner: provisioner)

        manager.start()
        let provisioning = await waitUntil(manager.state == .provisioning)
        XCTAssertTrue(provisioning)
        await manager.stop()
        XCTAssertEqual(manager.state, .terminated)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(manager.state, .terminated)
    }

    @MainActor
    func testGracefulStop() async {
        let fake = FakeHarnessProcess()
        let manager = makeManager(process: fake, healthResult: true)
        manager.start()
        fake.emitOutput("dsh web: http://127.0.0.1:43213\n")
        _ = await waitUntil(manager.state == .ready)
        await manager.stop()
        XCTAssertEqual(manager.state, .terminated)
        XCTAssertEqual(fake.forceCount, 0)
    }

    @MainActor
    func testStopAfterRestartStopsTheCurrentProcess() async {
        let fake = FakeHarnessProcess()
        let manager = makeManager(process: fake, healthResult: true, gracefulTimeout: 0.01)

        manager.start()
        fake.emitOutput("dsh web: http://127.0.0.1:43216\n")
        _ = await waitUntil(manager.state == .ready)
        await manager.stop()

        manager.start()
        fake.emitOutput("dsh web: http://127.0.0.1:43217\n")
        _ = await waitUntil(manager.state == .ready)
        await manager.stop()

        XCTAssertEqual(manager.state, .terminated)
        XCTAssertEqual(fake.gracefulCount, 2)
    }

    @MainActor
    func testForcedStop() async {
        let fake = FakeHarnessProcess()
        fake.ignoreGracefulTermination = true
        let manager = makeManager(process: fake, gracefulTimeout: 0.05)
        manager.start()
        await manager.stop()
        XCTAssertEqual(manager.state, .terminated)
        XCTAssertEqual(fake.forceCount, 1)
    }

    @MainActor
    func testRepeatedStopCallsCoalesce() async {
        let fake = FakeHarnessProcess()
        fake.ignoreGracefulTermination = true
        let manager = makeManager(process: fake, gracefulTimeout: 0.05)
        manager.start()
        async let first = manager.stop()
        async let second = manager.stop()
        _ = await (first, second)
        XCTAssertEqual(fake.forceCount, 1)
    }

    @MainActor
    private func makeManager(
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

    @MainActor
    private func testConfiguration(
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

    @MainActor
    private func waitUntil(
        _ condition: @autoclosure () -> Bool,
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
