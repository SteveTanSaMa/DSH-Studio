//
//  RuntimeManagerTests+Activation.swift
//  DSH Studio
//

import Foundation
import XCTest
@testable import DeepSeekRuntime
@testable import DeepSeekHarness
@testable import DeepSeekLogging

/// Activation cases: which Runtime the app records as the active one.
///
/// The durable record is what a restart reads, so it may only move to a Runtime that
/// actually became healthy: a launch that fails has to leave the previous record, and
/// the profile it is paired with, exactly where they were.
extension RuntimeManagerTests {

    /// A Runtime that never becomes healthy is never recorded as the active one.
    @MainActor
    func testAFailedHealthCheckDoesNotMoveTheActivationRecord() async throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-activation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let store = RuntimeDataProfileStore(supportDirectory: support)
        let root = support.appendingPathComponent("Runtimes/0.2.0-rc.2", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = try writeManifest(root: root)

        let process = FakeHarnessProcess()
        let manager = makeManager(
            process: process,
            healthResult: false,
            startupTimeout: 1,
            provisioner: FakeRuntimeProvisioner(root: root),
            dataProfileStore: store
        )
        // The manager resolves the active profile from its own DSH home, so the
        // record has to name that home for the launch to reach the health check.
        let profile = try store.ensureLegacyProfile(homeURL: manager.configuration.dshHome)
        _ = try store.activate(profile: profile, runtimeManifest: manifest)
        XCTAssertEqual(store.activeState()?.runtimeVersion, RuntimeRelease.runtimeVersion)

        manager.start()
        let launched = await waitUntil(process.launchCount == 1)
        XCTAssertTrue(launched)
        process.emitOutput("dsh web: http://127.0.0.1:43230\n")
        let failed = await waitUntil(manager.state == .failed, timeout: 5)

        XCTAssertTrue(
            failed,
            "expected the launch to fail, got \(manager.state): \(manager.logs.entries.suffix(6).map(\.message))"
        )
        guard case .healthCheckFailed = manager.lastError else {
            return XCTFail(
                "the health check has to be the failing gate, got \(String(describing: manager.lastError))"
            )
        }
        XCTAssertEqual(process.launchCount, 1, "the Runtime did launch, so health is what failed")
        XCTAssertEqual(
            store.activeState()?.runtimeVersion,
            RuntimeRelease.runtimeVersion,
            "the failing Runtime must not become the recorded one"
        )
        XCTAssertEqual(store.activeState()?.profileID, profile.id, "the profile pair stays intact")
    }

    /// Writes the pinned release as an installation manifest.
    ///
    /// - Parameter root: Runtime root that receives the manifest.
    /// - Returns: The manifest that was written.
    /// - Throws: When the manifest cannot be encoded or written.
    private func writeManifest(root: URL) throws -> RuntimeInstallationManifest {
        let architecture = "darwin-arm64"
        let manifest = RuntimeInstallationManifest(
            architecture: architecture,
            nodeVersion: RuntimeRelease.nodeVersion,
            harnessVersion: RuntimeRelease.harnessVersion,
            nodeSHA256: try XCTUnwrap(RuntimeRelease.nodeArchiveSHA256(architecture: architecture)),
            harnessPackageIntegrity: RuntimeRelease.harnessPackageIntegrity
        )
        try FileManager.default.createDirectory(
            at: RuntimeLocator.runtimeManifestURL(root: root).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(manifest).write(to: RuntimeLocator.runtimeManifestURL(root: root))
        return manifest
    }
}
