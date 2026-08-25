//
//  RuntimeUpdateCoordinatorTests.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import XCTest
@testable import DeepSeekHarness
@testable import DeepSeekRuntime

/// Verifies that a failed candidate Runtime is automatically rolled back.
final class RuntimeUpdateCoordinatorTests: XCTestCase {

    @MainActor
    func testFailedUpdatedRuntimeAutomaticallyRollsBackAndRestarts() async {
        let initialProcess = FakeHarnessProcess()
        let candidateProcess = FakeHarnessProcess()
        let rollbackProcess = FakeHarnessProcess()
        let health = QueueHealthChecker(results: [true, false, true])
        let updater = FakeRuntimeUpdater()
        let manager = RuntimeManager(
            configuration: RuntimeConfiguration(
                nodeExecutable: URL(fileURLWithPath: "/tmp/node"),
                harnessEntry: URL(fileURLWithPath: "/tmp/bin.js"),
                dshHome: URL(fileURLWithPath: "/tmp/dsh-home"),
                workspace: URL(fileURLWithPath: "/tmp/workspace"),
                startupTimeout: 0.2,
                gracefulTimeout: 0.05
            ),
            processFactory: SequencedProcessFactory(
                processes: [initialProcess, candidateProcess, rollbackProcess]
            ),
            healthChecker: health,
            validateRuntimeOnStart: false,
            updater: updater
        )

        manager.start()
        initialProcess.emitOutput("dsh web: http://127.0.0.1:43301\n")
        let initiallyReady = await waitUntil(manager.state == .ready)
        XCTAssertTrue(initiallyReady)

        let updateTask = Task { @MainActor in
            try await XCTUnwrap(manager.runtimeUpdateCoordinator).update()
        }
        let candidateLaunched = await waitUntil(candidateProcess.launchCount == 1)
        XCTAssertTrue(candidateLaunched)
        candidateProcess.emitOutput("dsh web: http://127.0.0.1:43302\n")

        let rollbackLaunched = await waitUntil(rollbackProcess.launchCount == 1)
        XCTAssertTrue(rollbackLaunched)
        rollbackProcess.emitOutput("dsh web: http://127.0.0.1:43303\n")

        do {
            try await updateTask.value
            XCTFail("expected the candidate Runtime to fail and roll back")
        } catch let error as RuntimeUpdateError {
            guard case .updateFailed = error else {
                return XCTFail("expected an update failure, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(updater.updateCount, 1)
        XCTAssertEqual(updater.rollbackCount, 1)
        XCTAssertEqual(manager.state, .ready)
    }

    @MainActor
    func testUnknownDataCompatibilityBlocksUpdateBeforeStoppingRuntime() async {
        let initialProcess = FakeHarnessProcess()
        let updater = FakeRuntimeUpdater(dataFormat: nil)
        let health = QueueHealthChecker(results: [true])
        let manager = RuntimeManager(
            configuration: RuntimeConfiguration(
                nodeExecutable: URL(fileURLWithPath: "/tmp/node"),
                harnessEntry: URL(fileURLWithPath: "/tmp/bin.js"),
                dshHome: URL(fileURLWithPath: "/tmp/dsh-home"),
                workspace: URL(fileURLWithPath: "/tmp/workspace"),
                startupTimeout: 0.2,
                gracefulTimeout: 0.05
            ),
            processFactory: FakeProcessFactory(process: initialProcess),
            healthChecker: health,
            validateRuntimeOnStart: false,
            updater: updater
        )

        manager.start()
        initialProcess.emitOutput("dsh web: http://127.0.0.1:43304\n")
        let initiallyReady = await waitUntil(manager.state == .ready)
        XCTAssertTrue(initiallyReady)

        do {
            try await XCTUnwrap(manager.runtimeUpdateCoordinator).update()
            XCTFail("expected unknown data compatibility to block the update")
        } catch let error as RuntimeUpdateError {
            XCTAssertEqual(error, .dataCompatibilityUnknown)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(updater.updateCount, 0)
        XCTAssertEqual(initialProcess.gracefulCount, 0)
        XCTAssertEqual(manager.state, .ready)
    }

    @MainActor
    func testCandidateUpdatePreparesWithoutStoppingThenActivatesOnSecondRequest() async {
        let initialProcess = FakeHarnessProcess()
        let updatedProcess = FakeHarnessProcess()
        let updater = FakeCandidateRuntimeUpdater()
        let health = QueueHealthChecker(results: [true, true])
        let manager = RuntimeManager(
            configuration: RuntimeConfiguration(
                nodeExecutable: URL(fileURLWithPath: "/tmp/node"),
                harnessEntry: URL(fileURLWithPath: "/tmp/bin.js"),
                dshHome: URL(fileURLWithPath: "/tmp/dsh-home"),
                workspace: URL(fileURLWithPath: "/tmp/workspace"),
                startupTimeout: 0.2,
                gracefulTimeout: 0.05
            ),
            processFactory: SequencedProcessFactory(
                processes: [initialProcess, updatedProcess]
            ),
            healthChecker: health,
            validateRuntimeOnStart: false,
            updater: updater
        )

        manager.start()
        initialProcess.emitOutput("dsh web: http://127.0.0.1:43305\n")
        let initiallyReady = await waitUntil(manager.state == .ready)
        XCTAssertTrue(initiallyReady)

        try? await XCTUnwrap(manager.runtimeUpdateCoordinator).prepare()

        XCTAssertEqual(updater.prepareCount, 1)
        XCTAssertEqual(updater.activateCount, 0)
        XCTAssertEqual(initialProcess.gracefulCount, 0)
        XCTAssertEqual(updatedProcess.launchCount, 0)
        XCTAssertEqual(manager.runtimeVersionStatus?.kind, .updatePrepared)
        XCTAssertEqual(manager.state, .ready)

        let activationTask = Task { @MainActor in
            try await XCTUnwrap(manager.runtimeUpdateCoordinator).update()
        }
        let updatedRuntimeLaunched = await waitUntil(updatedProcess.launchCount == 1)
        XCTAssertTrue(updatedRuntimeLaunched)
        updatedProcess.emitOutput("dsh web: http://127.0.0.1:43306\n")
        let updatedRuntimeReady = await waitUntil(manager.state == .ready)
        XCTAssertTrue(updatedRuntimeReady)
        _ = try? await activationTask.value

        XCTAssertEqual(updater.prepareCount, 1)
        XCTAssertEqual(updater.activateCount, 1)
        XCTAssertEqual(initialProcess.gracefulCount, 1)
        XCTAssertEqual(manager.configuration.expectedHarnessVersion, RuntimeRelease.harnessVersion)
    }

    @MainActor
    func testIncompatibleTargetProfileBlocksPreparedActivationBeforeStoppingRuntime() async throws {
        let initialProcess = FakeHarnessProcess()
        let updater = FakeCandidateRuntimeUpdater()
        let health = QueueHealthChecker(results: [true])
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepSeekStudio.RuntimeUpdateProfileTests-(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let store = RuntimeDataProfileStore(supportDirectory: support)
        let incompatibleProfile = try store.createProfile(
            name: "旧数据",
            dataFormatID: "sqlite-v2"
        )
        let manager = RuntimeManager(
            configuration: RuntimeConfiguration(
                nodeExecutable: URL(fileURLWithPath: "/tmp/node"),
                harnessEntry: URL(fileURLWithPath: "/tmp/bin.js"),
                dshHome: URL(fileURLWithPath: "/tmp/dsh-home"),
                workspace: URL(fileURLWithPath: "/tmp/workspace"),
                startupTimeout: 0.2,
                gracefulTimeout: 0.05
            ),
            processFactory: FakeProcessFactory(process: initialProcess),
            healthChecker: health,
            validateRuntimeOnStart: false,
            updater: updater,
            dataProfileStore: store
        )

        manager.start()
        initialProcess.emitOutput("dsh web: http://127.0.0.1:43307\n")
        let initiallyReady = await waitUntil(manager.state == .ready)
        XCTAssertTrue(initiallyReady)

        try await XCTUnwrap(manager.runtimeUpdateCoordinator).prepare()

        do {
            try await XCTUnwrap(manager.runtimeUpdateCoordinator).update(using: incompatibleProfile)
            XCTFail("expected incompatible target profile to block activation")
        } catch let error as RuntimeUpdateError {
            XCTAssertEqual(error, .dataIncompatible)
        }

        XCTAssertEqual(initialProcess.gracefulCount, 0)
        XCTAssertEqual(updater.activateCount, 0)
        XCTAssertEqual(manager.state, .ready)
    }

    @MainActor
    func waitUntil(
        _ condition: @autoclosure @escaping () -> Bool,
        timeout: TimeInterval = 2
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}
