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
    private func waitUntil(
        _ condition: @autoclosure () -> Bool,
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

private final class FakeRuntimeUpdater: RuntimeUpdating, @unchecked Sendable {
    let root = URL(fileURLWithPath: "/tmp/runtime")
    let architecture = "darwin-arm64"
    private(set) var updateCount = 0
    private(set) var rollbackCount = 0

    private let oldManifest = RuntimeInstallationManifest(
        architecture: "darwin-arm64",
        nodeVersion: "24.18.0",
        harnessVersion: "0.1.0-rc.5",
        nodeSHA256: "old-node-sha",
        harnessPackageIntegrity: "old-harness-integrity"
    )
    private let newManifest = RuntimeInstallationManifest(
        architecture: "darwin-arm64",
        nodeVersion: RuntimeRelease.nodeVersion,
        harnessVersion: RuntimeRelease.harnessVersion,
        nodeSHA256: "new-node-sha",
        harnessPackageIntegrity: RuntimeRelease.harnessPackageIntegrity
    )

    func versionStatus() -> RuntimeVersionStatus {
        RuntimeVersionStatus(
            kind: updateCount > rollbackCount ? .current : .updateAvailable,
            installed: updateCount > rollbackCount ? newManifest : oldManifest,
            available: RuntimeRelease.descriptor(architecture: architecture)!,
            rollbackAvailable: updateCount > 0
        )
    }

    func provision() async throws -> RuntimeProvisioningResult {
        RuntimeProvisioningResult(
            root: root,
            architecture: architecture,
            manifest: newManifest
        )
    }

    func update() async throws -> RuntimeProvisioningResult {
        updateCount += 1
        return RuntimeProvisioningResult(
            root: root,
            architecture: architecture,
            manifest: newManifest
        )
    }

    func rollback() throws -> RuntimeProvisioningResult {
        rollbackCount += 1
        return RuntimeProvisioningResult(
            root: root,
            architecture: architecture,
            manifest: oldManifest
        )
    }
}

private final class QueueHealthChecker: HarnessHealthChecking, @unchecked Sendable {
    private let box: ResultBox

    init(results: [Bool]) {
        self.box = ResultBox(results: results)
    }

    func check(baseURL: URL, timeout: TimeInterval) async -> Bool {
        await box.next()
    }
}

private actor ResultBox {
    private var results: [Bool]

    init(results: [Bool]) {
        self.results = results
    }

    func next() -> Bool {
        results.isEmpty ? false : results.removeFirst()
    }
}
