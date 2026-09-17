import XCTest
@testable import DeepSeekHarness
@testable import DeepSeekRuntime

/// Single-step updater double for the legacy update path.
///
/// `update()` and `rollback()` only move counters, so a test can drive the
/// coordinator through both branches without touching the file system.
final class FakeRuntimeUpdater: RuntimeUpdating, @unchecked Sendable {
    /// Installation root reported by every result.
    let root = URL(fileURLWithPath: "/tmp/runtime")
    /// Architecture reported by every result.
    let architecture = "darwin-arm64"
    private(set) var updateCount = 0
    private(set) var rollbackCount = 0

    private let oldManifest: RuntimeInstallationManifest
    private let newManifest: RuntimeInstallationManifest
    private let availableRelease: RuntimeReleaseDescriptor

    /// Creates the double with an optional data contract.
    ///
    /// - Parameter dataFormat: Contract recorded in both manifests and the release;
    ///   passing `nil` simulates a release that declares no format.
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

    /// Reports an update as available until ``update()`` has run.
    ///
    /// After an update the status flips to current, and a rollback target appears.
    ///
    /// - Returns: The status derived from the update and rollback counters.
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

    /// Reports the new manifest without counting an update.
    func provision() async throws -> RuntimeProvisioningResult {
        RuntimeProvisioningResult(
            root: root,
            architecture: architecture,
            manifest: newManifest
        )
    }

    /// Counts an update and reports the new manifest.
    func update() async throws -> RuntimeProvisioningResult {
        updateCount += 1
        return RuntimeProvisioningResult(
            root: root,
            architecture: architecture,
            manifest: newManifest
        )
    }

    /// Counts a rollback and reports the old manifest.
    func rollback() throws -> RuntimeProvisioningResult {
        rollbackCount += 1
        return RuntimeProvisioningResult(
            root: root,
            architecture: architecture,
            manifest: oldManifest
        )
    }
}

/// Two-phase updater double for the prepare-then-activate flow.
///
/// The double models the real contract: activation only succeeds after a
/// preparation, which is what lets tests prove the coordinator never activates an
/// unprepared candidate.
final class FakeCandidateRuntimeUpdater: RuntimeCandidateUpdating, @unchecked Sendable {
    /// Installation root reported by every result.
    let root = URL(fileURLWithPath: "/tmp/runtime-candidate")
    /// Architecture reported by every result.
    let architecture = "darwin-arm64"
    private(set) var prepareCount = 0
    private(set) var activateCount = 0

    private let oldManifest: RuntimeInstallationManifest
    private let newManifest: RuntimeInstallationManifest
    private let availableRelease: RuntimeReleaseDescriptor
    private var prepared = false
    private var active = false

    /// Creates the double in its not-yet-prepared state.
    init() {
        let dataFormat = RuntimeDataFormatDescriptor(id: "sqlite-v1")
        oldManifest = RuntimeInstallationManifest(
            runtimeVersion: "old-runtime",
            architecture: "darwin-arm64",
            nodeVersion: "24.18.0",
            harnessVersion: "legacy-harness",
            nodeSHA256: "old-node-sha",
            harnessPackageIntegrity: "old-harness-integrity",
            dataFormat: dataFormat
        )
        newManifest = RuntimeInstallationManifest(
            runtimeVersion: "new-runtime",
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            harnessVersion: RuntimeRelease.harnessVersion,
            nodeSHA256: "new-node-sha",
            harnessPackageIntegrity: "new-harness-integrity",
            dataFormat: dataFormat
        )
        availableRelease = RuntimeReleaseDescriptor(
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            harnessVersion: RuntimeRelease.harnessVersion,
            pnpmVersion: "11.7.0",
            nodeArchiveSHA256: "new-node-sha",
            harnessPackageIntegrity: "new-harness-integrity",
            pnpmPackageIntegrity: "pnpm-integrity",
            runtimeVersion: "new-runtime",
            dataFormat: dataFormat
        )
    }

    /// Reports available, prepared, or current according to the double's progress.
    ///
    /// - Returns: The status for the current prepare and activate state.
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

    /// Reports the new manifest without preparing anything.
    func provision() async throws -> RuntimeProvisioningResult {
        RuntimeProvisioningResult(root: root, architecture: architecture, manifest: newManifest)
    }

    /// Marks a candidate prepared and counts the call.
    ///
    /// - Returns: A result carrying the new manifest.
    func prepareUpdate() async throws -> RuntimeProvisioningResult {
        prepareCount += 1
        prepared = true
        return RuntimeProvisioningResult(root: root, architecture: architecture, manifest: newManifest)
    }

    /// Activates the prepared candidate.
    ///
    /// - Returns: A result carrying the new manifest.
    /// - Throws: ``RuntimeUpdateError/noUpdateAvailable`` when nothing was prepared,
    ///   mirroring the production guarantee.
    func activatePreparedUpdate() throws -> RuntimeProvisioningResult {
        guard prepared else { throw RuntimeUpdateError.noUpdateAvailable }
        activateCount += 1
        active = true
        return RuntimeProvisioningResult(root: root, architecture: architecture, manifest: newManifest)
    }

    /// Prepares and then activates, so tests can use one call for the full flow.
    func update() async throws -> RuntimeProvisioningResult {
        _ = try await prepareUpdate()
        return try activatePreparedUpdate()
    }

    /// Returns the double to its pre-update state.
    func rollback() throws -> RuntimeProvisioningResult {
        active = false
        prepared = false
        return RuntimeProvisioningResult(root: root, architecture: architecture, manifest: oldManifest)
    }
}

/// Answers health checks from a fixed queue of results.
final class QueueHealthChecker: HarnessHealthChecking, @unchecked Sendable {
    private let box: ResultBox

    /// Creates a checker over a fixed sequence of answers.
    ///
    /// - Parameter results: Answers returned in order.
    init(results: [Bool]) {
        self.box = ResultBox(results: results)
    }

    /// Returns the next queued answer, or `false` once the queue is empty.
    func check(baseURL: URL, timeout: TimeInterval) async -> Bool {
        await box.next()
    }
}

/// Serializes the queued health-check answers for concurrent callers.
actor ResultBox {
    private var results: [Bool]

    /// Creates a box over a fixed sequence of answers.
    ///
    /// - Parameter results: Answers returned in order.
    init(results: [Bool]) {
        self.results = results
    }

    /// Removes and returns the next answer.
    ///
    /// - Returns: The next queued answer, or `false` when the queue is empty.
    func next() -> Bool {
        results.isEmpty ? false : results.removeFirst()
    }
}
