import XCTest
@testable import DeepSeekHarness
@testable import DeepSeekRuntime

final class FakeRuntimeUpdater: RuntimeUpdating, @unchecked Sendable {
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

final class FakeCandidateRuntimeUpdater: RuntimeCandidateUpdating, @unchecked Sendable {
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

final class QueueHealthChecker: HarnessHealthChecking, @unchecked Sendable {
    private let box: ResultBox

    init(results: [Bool]) {
        self.box = ResultBox(results: results)
    }

    func check(baseURL: URL, timeout: TimeInterval) async -> Bool {
        await box.next()
    }
}

actor ResultBox {
    private var results: [Bool]

    init(results: [Bool]) {
        self.results = results
    }

    func next() -> Bool {
        results.isEmpty ? false : results.removeFirst()
    }
}
