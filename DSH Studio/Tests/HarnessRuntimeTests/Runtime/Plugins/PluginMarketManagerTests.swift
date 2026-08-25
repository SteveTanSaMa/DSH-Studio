import Foundation
import XCTest
@testable import DeepSeekRuntime
@testable import DeepSeekHarness

@MainActor
final class PluginMarketManagerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSHStudio-PluginMarketManager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testRefreshClassifiesEmptyProfileAsNotInstalled() async throws {
        let manager = makeManager()

        await manager.refresh()

        XCTAssertEqual(manager.state.installState, .notInstalled)
        XCTAssertTrue(manager.state.compatibleHarness)
    }

    func testRefreshClassifiesCompleteFixedInstallationAsInstalled() async throws {
        let manager = makeManager()
        try writeCompleteFixture(in: manager.profileStore)

        await manager.refresh()

        XCTAssertEqual(manager.state.installState, .installed)
        XCTAssertEqual(manager.state.installedVersion, PluginMarketRelease.packageVersion)
        XCTAssertTrue(manager.state.enabled)
    }

    func testRefreshClassifiesMissingBundleRegistrationAsCorrupted() async throws {
        let manager = makeManager()
        try writeCompleteFixture(in: manager.profileStore, includeBundle: false)

        await manager.refresh()

        XCTAssertEqual(manager.state.installState, .corrupted)
    }

    func testRefreshClassifiesMalformedPackageJSONAsCorrupted() async throws {
        let manager = makeManager()
        try manager.profileStore.ensureProfileDirectory()
        try write(
            "{ this is not json",
            to: manager.profileStore.profileDirectory.appendingPathComponent("package.json")
        )

        await manager.refresh()

        XCTAssertEqual(manager.state.installState, .corrupted)
    }

    func testRefreshClassifiesLegacyHarnessAsIncompatible() async throws {
        let manager = makeManager(harnessVersion: "0.1.0-rc.6")

        await manager.refresh()

        XCTAssertEqual(manager.state.installState, .incompatible)
        XCTAssertFalse(manager.state.compatibleHarness)
    }

    func testRefreshClassifiesRuntimeTransitionSeparatelyFromInstallState() async throws {
        let manager = makeManager()
        manager.runtime.setRuntimeOperationState(.starting)

        await manager.refresh()

        XCTAssertEqual(manager.state.installState, .runtimeUnavailable)
    }

    func testPluginMarketIsUnavailableOutsideWebProfile() async throws {
        let manager = makeManager(profileName: "review")

        await manager.refresh()

        XCTAssertEqual(manager.state.installState, .unavailable)
        XCTAssertEqual(manager.state.statusError, "仅 web Profile 可用")
        do {
            try await manager.install()
            XCTFail("custom Profiles must not mutate the web Plugin Market profile")
        } catch let error as PluginMarketManagerError {
            XCTAssertEqual(error, .unavailable("仅 web Profile 可用"))
        }
    }

    func testProfileStoreFollowsRuntimeDataHomeChanges() throws {
        let manager = makeManager()
        let updatedHome = temporaryDirectory.appendingPathComponent("Updated-DSH_HOME", isDirectory: true)

        manager.runtime.configuration.dshHome = updatedHome

        XCTAssertEqual(manager.profileStore.dshHome, updatedHome.standardizedFileURL)
        XCTAssertEqual(
            manager.profileStore.profileDirectory,
            updatedHome.appendingPathComponent("profiles/web", isDirectory: true)
        )
    }

    func testInstallSuccessMaterializesAndRecordsFixedPackage() async throws {
        let store = PluginMarketProfileStore(
            dshHome: temporaryDirectory.appendingPathComponent("DSH_HOME", isDirectory: true)
        )
        let runner = MaterializingPluginMarketCommandRunner(
            store: store,
            outcome: .installSuccess
        )
        let manager = makeManager(
            commandRunner: runner,
            dshHome: store.dshHome
        )

        try await manager.install()

        XCTAssertTrue(try manager.profileStore.validateExpectedInstallation().entryPointValid)
        XCTAssertEqual(manager.state.installState, .installed)
        XCTAssertEqual(manager.state.lastOperation?.operation, .install)
        XCTAssertEqual(manager.state.lastOperation?.succeeded, true)
    }

    func testEnsureInstalledInstallsMissingFixedPackage() async throws {
        let store = PluginMarketProfileStore(
            dshHome: temporaryDirectory.appendingPathComponent("DSH_HOME", isDirectory: true)
        )
        let runner = MaterializingPluginMarketCommandRunner(
            store: store,
            outcome: .installSuccess
        )
        let manager = makeManager(
            commandRunner: runner,
            dshHome: store.dshHome
        )

        let installed = try await manager.ensureInstalled()

        XCTAssertTrue(installed)
        XCTAssertEqual(manager.state.installState, .installed)
        XCTAssertEqual(manager.state.installedVersion, PluginMarketRelease.packageVersion)
    }

    func testEnsureInstalledLeavesValidInstallationForMarketToManage() async throws {
        let manager = makeManager()
        try writeCompleteFixture(in: manager.profileStore)

        let installed = try await manager.ensureInstalled()

        XCTAssertFalse(installed)
        XCTAssertEqual(manager.state.installState, .installed)
    }

    func testCommandFailureRestoresProfileAndPnpmMaterialization() async throws {
        let store = PluginMarketProfileStore(
            dshHome: temporaryDirectory.appendingPathComponent("DSH_HOME", isDirectory: true)
        )
        let runner = MaterializingPluginMarketCommandRunner(
            store: store,
            outcome: .failAfterMutation
        )
        let manager = makeManager(
            commandRunner: runner,
            dshHome: store.dshHome
        )

        do {
            try await manager.install()
            XCTFail("the command failure should be surfaced")
        } catch {
            XCTAssertTrue(error is PluginMarketManagerError)
        }

        XCTAssertNil(try manager.profileStore.inspect().dependencySpec)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.profileDirectory
                    .appendingPathComponent("node_modules/.pnpm/dshmarket@\(PluginMarketRelease.packageVersion)")
                    .path
            )
        )
        XCTAssertEqual(manager.state.installState, .notInstalled)
        XCTAssertEqual(manager.state.lastOperation?.succeeded, false)
        XCTAssertNotNil(manager.state.statusError)
    }

    func testConcurrentOperationIsRejectedBySingleFlightGuard() async throws {
        let manager = makeManager()
        let errors = await withTaskGroup(of: Error?.self, returning: [Error?].self) { group in
            for _ in 0..<2 {
                group.addTask { @MainActor in
                    do {
                        try await manager.install()
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            var results: [Error?] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        XCTAssertTrue(
            errors.contains { error in
                guard let error = error as? PluginMarketManagerError else { return false }
                return error == .operationInProgress
            }
        )
    }

    func testRuntimeRestartFailureRestoresPreviousProfileAndReportsFailure() async throws {
        let process = FakeHarnessProcess()
        let health = SequencedPluginMarketHealthChecker(results: [true, false, false])
        let store = PluginMarketProfileStore(
            dshHome: temporaryDirectory.appendingPathComponent("DSH_HOME", isDirectory: true)
        )
        let runner = MaterializingPluginMarketCommandRunner(store: store, outcome: .success)
        let manager = makeManager(
            commandRunner: runner,
            process: process,
            healthChecker: health,
            dshHome: store.dshHome,
            gracefulTimeout: 0.01
        )
        try writeCompleteFixture(in: manager.profileStore)

        manager.runtime.start()
        process.emitOutput("dsh web: http://127.0.0.1:43250\n")
        let runtimeReady = await waitUntil(manager.runtime.state == RuntimeState.ready)
        XCTAssertTrue(runtimeReady)

        do {
            try await manager.update()
            XCTFail("restart failure should be surfaced")
        } catch {
            XCTAssertTrue(error is PluginMarketManagerError)
        }

        XCTAssertEqual(manager.runtime.state, RuntimeState.failed)
        XCTAssertTrue(try manager.profileStore.validateExpectedInstallation().entryPointValid)
        XCTAssertEqual(manager.state.lastOperation?.operation, .update)
        XCTAssertEqual(manager.state.lastOperation?.succeeded, false)
        XCTAssertNotNil(manager.state.statusError)
    }

    func testPluginCommandDisablesInstallScripts() async throws {
        let runner = RecordingPluginMarketCommandRunner()
        let manager = makeManager(commandRunner: runner)

        do {
            try await manager.install()
            XCTFail("an unchanged empty fixture should fail post-install validation")
        } catch {
            // The fake command runner does not materialize a package. The test
            // is only asserting the security environment at the process edge.
        }

        XCTAssertEqual(runner.lastEnvironment?["npm_config_ignore_scripts"], "true")
        XCTAssertEqual(runner.lastEnvironment?["NPM_CONFIG_IGNORE_SCRIPTS"], "true")
        XCTAssertEqual(runner.lastEnvironment?["npm_config_registry"], "https://registry.npmjs.org/")
    }

    private func makeManager(
        harnessVersion: String = PluginMarketRelease.compatibleHarnessVersion,
        commandRunner: any RuntimeCommandRunning = RecordingPluginMarketCommandRunner(),
        process: FakeHarnessProcess = FakeHarnessProcess(),
        healthChecker: (any HarnessHealthChecking)? = nil,
        dshHome: URL? = nil,
        profileName: String = PluginMarketRelease.profileName,
        startupTimeout: TimeInterval = 1,
        gracefulTimeout: TimeInterval = 0.01
    ) -> PluginMarketManager {
        let root = temporaryDirectory.appendingPathComponent("Runtime", isDirectory: true)
        let node = RuntimeLocator.nodeExecutable(
            root: root,
            architecture: "darwin-arm64"
        )
        let harness = RuntimeLocator.harnessEntry(
            root: root,
            architecture: "darwin-arm64",
            harnessVersion: harnessVersion
        )
        let pnpm = RuntimeLocator.pnpmExecutable(
            root: root,
            architecture: "darwin-arm64",
            harnessVersion: harnessVersion
        )
        try! FileManager.default.createDirectory(at: node.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("#!/bin/sh\n".utf8).write(to: node)
        try! FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: node.path
        )
        try! FileManager.default.createDirectory(at: harness.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("#!/usr/bin/env node\n".utf8).write(to: harness)
        try! Data(
            "{\"name\":\"@deepseek-ai/dsh\",\"version\":\"\(harnessVersion)\"}".utf8
        ).write(to: harness.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("package.json"))
        try! FileManager.default.createDirectory(at: pnpm.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("#!/bin/sh\n".utf8).write(to: pnpm)
        try! FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: pnpm.path
        )

        let configuration = RuntimeConfiguration(
            nodeExecutable: node,
            harnessEntry: harness,
            dshHome: dshHome ?? temporaryDirectory.appendingPathComponent("DSH_HOME", isDirectory: true),
            workspace: temporaryDirectory.appendingPathComponent("Workspace", isDirectory: true),
            pnpmExecutable: pnpm,
            startupTimeout: startupTimeout,
            gracefulTimeout: gracefulTimeout,
            profileName: profileName
        )
        let runtime = RuntimeManager(
            configuration: configuration,
            processFactory: FakeProcessFactory(process: process),
            healthChecker: healthChecker ?? FakeHealthChecker(result: true),
            validateRuntimeOnStart: false
        )
        return PluginMarketManager(
            runtime: runtime,
            commandRunner: commandRunner,
            supportDirectory: temporaryDirectory.appendingPathComponent("Support", isDirectory: true)
        )
    }

    private func waitUntil(
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

    private func writeCompleteFixture(
        in store: PluginMarketProfileStore,
        includeBundle: Bool = true
    ) throws {
        try store.ensureProfileDirectory()
        let bundles = includeBundle ? "[\"dshmarket\"]" : "[]"
        try write(
            "{\"dependencies\":{\"dshmarket\":\"\(PluginMarketRelease.packageVersion)\"},\"dsh\":{\"profile\":{\"bundles\":\(bundles)}}}",
            to: store.profileDirectory.appendingPathComponent("package.json")
        )
        try write(
            "{\"name\":\"dshmarket\",\"version\":\"\(PluginMarketRelease.packageVersion)\",\"main\":\"lib/index.js\",\"dsh\":{\"bundle\":{\"patch\":\"./cordis.patch.yml\"}}}",
            to: store.profileDirectory.appendingPathComponent("node_modules/dshmarket/package.json")
        )
        try write(
            "// bundled entry",
            to: store.profileDirectory.appendingPathComponent("node_modules/dshmarket/lib/index.js")
        )
        try write(
            "# dsh bundle patch: inserts this plugin into a profile's layer stack.\n- insert:\n    - id: dsh-market\n      name: 'dshmarket'\n",
            to: store.profileDirectory.appendingPathComponent("node_modules/dshmarket/cordis.patch.yml")
        )
        try write(
            "lockfileVersion: '9.0'\npackages:\n  dshmarket@\(PluginMarketRelease.packageVersion):\n    resolution: {}\n    integrity: \(PluginMarketRelease.packageIntegrity)\n",
            to: store.profileDirectory.appendingPathComponent("pnpm-lock.yaml")
        )
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

private final class RecordingPluginMarketCommandRunner: RuntimeCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var environment: [String: String]?

    var lastEnvironment: [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        return environment
    }

    func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String]
    ) throws -> RuntimeCommandResult {
        lock.lock()
        self.environment = environment
        lock.unlock()
        return RuntimeCommandResult(status: 0, stdout: "", stderr: "")
    }
}

private final class MaterializingPluginMarketCommandRunner: RuntimeCommandRunning, @unchecked Sendable {
    enum Outcome: Sendable {
        case installSuccess
        case failAfterMutation
        case success
    }

    private let store: PluginMarketProfileStore
    private let outcome: Outcome

    init(store: PluginMarketProfileStore, outcome: Outcome) {
        self.store = store
        self.outcome = outcome
    }

    func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String]
    ) throws -> RuntimeCommandResult {
        switch outcome {
        case .installSuccess:
            try writeCompleteFixture()
            return RuntimeCommandResult(status: 0, stdout: "", stderr: "")
        case .failAfterMutation:
            try store.ensureProfileDirectory()
            try write(
                "{\"dependencies\":{\"dshmarket\":\"\(PluginMarketRelease.packageVersion)\"}}",
                to: store.profileDirectory.appendingPathComponent("package.json")
            )
            let packageRoot = store.profileDirectory
                .appendingPathComponent("node_modules/.pnpm/dshmarket@\(PluginMarketRelease.packageVersion)", isDirectory: true)
            try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
            try write("partial", to: packageRoot.appendingPathComponent("package.json"))
            return RuntimeCommandResult(status: 23, stdout: "", stderr: "simulated command failure")
        case .success:
            return RuntimeCommandResult(status: 0, stdout: "", stderr: "")
        }
    }

    private func writeCompleteFixture() throws {
        try store.ensureProfileDirectory()
        try write(
            "{\"dependencies\":{\"dshmarket\":\"\(PluginMarketRelease.packageVersion)\"},\"dsh\":{\"profile\":{\"bundles\":[\"dshmarket\"]}}}",
            to: store.profileDirectory.appendingPathComponent("package.json")
        )
        try write(
            "{\"name\":\"dshmarket\",\"version\":\"\(PluginMarketRelease.packageVersion)\",\"main\":\"lib/index.js\",\"dsh\":{\"bundle\":{\"patch\":\"./cordis.patch.yml\"}}}",
            to: store.profileDirectory.appendingPathComponent("node_modules/dshmarket/package.json")
        )
        try write(
            "// bundled entry",
            to: store.profileDirectory.appendingPathComponent("node_modules/dshmarket/lib/index.js")
        )
        try write(
            "# dsh bundle patch: inserts this plugin into a profile's layer stack.\n- insert:\n    - id: dsh-market\n      name: 'dshmarket'\n",
            to: store.profileDirectory.appendingPathComponent("node_modules/dshmarket/cordis.patch.yml")
        )
        try write(
            "lockfileVersion: '9.0'\npackages:\n  dshmarket@\(PluginMarketRelease.packageVersion):\n    resolution: {}\n    integrity: \(PluginMarketRelease.packageIntegrity)\n",
            to: store.profileDirectory.appendingPathComponent("pnpm-lock.yaml")
        )
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }
}

private actor PluginMarketHealthSequence {
    private var results: [Bool]

    init(results: [Bool]) {
        self.results = results
    }

    func next() -> Bool {
        guard !results.isEmpty else { return false }
        return results.removeFirst()
    }
}

private final class SequencedPluginMarketHealthChecker: HarnessHealthChecking, @unchecked Sendable {
    private let sequence: PluginMarketHealthSequence

    init(results: [Bool]) {
        self.sequence = PluginMarketHealthSequence(results: results)
    }

    func check(baseURL: URL, timeout: TimeInterval) async -> Bool {
        await sequence.next()
    }
}
