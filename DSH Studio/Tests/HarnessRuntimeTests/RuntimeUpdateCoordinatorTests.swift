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
        XCTAssertEqual(manager.configuration.expectedHarnessVersion, "0.1.0-rc.7")
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

    private let oldManifest: RuntimeInstallationManifest
    private let newManifest: RuntimeInstallationManifest
    private let availableRelease: RuntimeReleaseDescriptor

    init(dataFormat: RuntimeDataFormatDescriptor? = RuntimeDataFormatDescriptor(id: "sqlite-v1")) {
        let base = RuntimeRelease.descriptor(architecture: "darwin-arm64")!
        oldManifest = RuntimeInstallationManifest(
            runtimeVersion: "old-runtime",
            architecture: "darwin-arm64",
            nodeVersion: "24.18.0",
            harnessVersion: "0.1.0-rc.5",
            nodeSHA256: "old-node-sha",
            harnessPackageIntegrity: "old-harness-integrity",
            dataFormat: dataFormat
        )
        newManifest = RuntimeInstallationManifest(
            runtimeVersion: base.runtimeVersion,
            architecture: "darwin-arm64",
            nodeVersion: RuntimeRelease.nodeVersion,
            harnessVersion: RuntimeRelease.harnessVersion,
            nodeSHA256: "new-node-sha",
            harnessPackageIntegrity: RuntimeRelease.harnessPackageIntegrity,
            dataFormat: dataFormat
        )
        availableRelease = RuntimeReleaseDescriptor(
            architecture: base.architecture,
            nodeVersion: base.nodeVersion,
            harnessVersion: base.harnessVersion,
            pnpmVersion: base.pnpmVersion,
            nodeArchiveSHA256: base.nodeArchiveSHA256,
            harnessPackageIntegrity: base.harnessPackageIntegrity,
            pnpmPackageIntegrity: base.pnpmPackageIntegrity,
            runtimeVersion: base.runtimeVersion,
            artifact: base.artifact,
            dataFormat: dataFormat
        )
    }

    func versionStatus() -> RuntimeVersionStatus {
        RuntimeVersionStatus(
            kind: updateCount > rollbackCount ? .current : .updateAvailable,
            installed: updateCount > rollbackCount ? newManifest : oldManifest,
            available: availableRelease,
            activeProfileID: "legacy-profile",
            activeDataFormatID: newManifest.dataFormat?.id,
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

private final class FakeCandidateRuntimeUpdater: RuntimeCandidateUpdating, @unchecked Sendable {
    let root = URL(fileURLWithPath: "/tmp/runtime-candidate")
    let architecture = "darwin-arm64"
    private(set) var prepareCount = 0
    private(set) var activateCount = 0

    private let oldManifest: RuntimeInstallationManifest
    private let newManifest: RuntimeInstallationManifest
    private let availableRelease: RuntimeReleaseDescriptor
    private var prepared = false
    private var active = false

    init() {
        let dataFormat = RuntimeDataFormatDescriptor(id: "sqlite-v1")
        oldManifest = RuntimeInstallationManifest(
            runtimeVersion: "old-runtime",
            architecture: "darwin-arm64",
            nodeVersion: "24.18.0",
            harnessVersion: "0.1.0-rc.6",
            nodeSHA256: "old-node-sha",
            harnessPackageIntegrity: "old-harness-integrity",
            dataFormat: dataFormat
        )
        newManifest = RuntimeInstallationManifest(
            runtimeVersion: "new-runtime",
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            harnessVersion: "0.1.0-rc.7",
            nodeSHA256: "new-node-sha",
            harnessPackageIntegrity: "new-harness-integrity",
            dataFormat: dataFormat
        )
        availableRelease = RuntimeReleaseDescriptor(
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            harnessVersion: "0.1.0-rc.7",
            pnpmVersion: "11.7.0",
            nodeArchiveSHA256: "new-node-sha",
            harnessPackageIntegrity: "new-harness-integrity",
            pnpmPackageIntegrity: "pnpm-integrity",
            runtimeVersion: "new-runtime",
            dataFormat: dataFormat
        )
    }

    func versionStatus() -> RuntimeVersionStatus {
        RuntimeVersionStatus(
            kind: active ? .current : (prepared ? .updatePrepared : .updateAvailable),
            installed: active ? newManifest : oldManifest,
            available: availableRelease,
            prepared: prepared ? newManifest : nil,
            activeProfileID: "legacy-profile",
            activeDataFormatID: newManifest.dataFormat?.id,
            rollbackAvailable: false
        )
    }

    func provision() async throws -> RuntimeProvisioningResult {
        RuntimeProvisioningResult(root: root, architecture: architecture, manifest: newManifest)
    }

    func prepareUpdate() async throws -> RuntimeProvisioningResult {
        prepareCount += 1
        prepared = true
        return RuntimeProvisioningResult(root: root, architecture: architecture, manifest: newManifest)
    }

    func activatePreparedUpdate() throws -> RuntimeProvisioningResult {
        guard prepared else { throw RuntimeUpdateError.noUpdateAvailable }
        activateCount += 1
        active = true
        return RuntimeProvisioningResult(root: root, architecture: architecture, manifest: newManifest)
    }

    func update() async throws -> RuntimeProvisioningResult {
        _ = try await prepareUpdate()
        return try activatePreparedUpdate()
    }

    func rollback() throws -> RuntimeProvisioningResult {
        active = false
        prepared = false
        return RuntimeProvisioningResult(root: root, architecture: architecture, manifest: oldManifest)
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
