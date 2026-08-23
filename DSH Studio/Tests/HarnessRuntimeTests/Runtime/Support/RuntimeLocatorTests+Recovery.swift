import XCTest
@testable import DeepSeekRuntime

extension RuntimeLocatorTests {

    func testRuntimeRootUsesMatchingLegacyDuringRecovery() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepSeekStudio.RuntimeRootRecovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let legacyRoot = support.appendingPathComponent("Runtime", isDirectory: true)
        try makeRuntimeFixture(
            root: legacyRoot,
            runtimeVersion: "old-runtime",
            harnessVersion: "0.1.0-rc.7"
        )
        let activeState = RuntimeActiveState(
            profileID: "legacy-profile",
            runtimeVersion: "old-runtime",
            dataFormatID: "sqlite-v1"
        )
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try JSONEncoder().encode(activeState).write(
            to: support.appendingPathComponent("active-state.json"),
            options: .atomic
        )

        XCTAssertEqual(
            RuntimeLocator.runtimeRoot(
                fileManager: .default,
                supportDirectory: support
            ),
            legacyRoot
        )
    }

    func testRuntimeRootDoesNotUseUnrelatedLegacyWhenActiveTargetIsMissing() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepSeekStudio.RuntimeRootConflict-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let legacyRoot = support.appendingPathComponent("Runtime", isDirectory: true)
        try makeRuntimeFixture(
            root: legacyRoot,
            runtimeVersion: "old-runtime",
            harnessVersion: "0.1.0-rc.7"
        )
        let activeRoot = try XCTUnwrap(
            RuntimeLocator.versionedRuntimeRoot(
                supportDirectory: support,
                runtimeVersion: "new-runtime"
            )
        )
        let activeState = RuntimeActiveState(
            profileID: "legacy-profile",
            runtimeVersion: "new-runtime",
            dataFormatID: "sqlite-v2"
        )
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try JSONEncoder().encode(activeState).write(
            to: support.appendingPathComponent("active-state.json"),
            options: .atomic
        )

        XCTAssertEqual(
            RuntimeLocator.runtimeRoot(
                fileManager: .default,
                supportDirectory: support
            ),
            activeRoot
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyRoot.path))
    }

    func testIncompleteActivationRestoresRuntimeMatchingActiveState() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepSeekStudio.RuntimeRecovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let root = support.appendingPathComponent("Runtime", isDirectory: true)
        let backup = RuntimeLocator.rollbackRoot(root: root)
        try makeRuntimeFixture(root: root, runtimeVersion: "new-runtime", harnessVersion: "0.1.0-rc.8")
        try makeRuntimeFixture(root: backup, runtimeVersion: "old-runtime", harnessVersion: "0.1.0-rc.7")

        let state = RuntimeActiveState(
            profileID: "legacy-profile",
            runtimeVersion: "old-runtime",
            dataFormatID: "sqlite-v1"
        )
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(
            to: support.appendingPathComponent("active-state.json"),
            options: .atomic
        )

        XCTAssertTrue(
            RuntimeLocator.recoverIncompleteActivation(
                supportDirectory: support,
                architecture: "darwin-arm64"
            )
        )
        XCTAssertEqual(
            RuntimeLocator.installationManifest(root: root)?.runtimeVersion,
            "old-runtime"
        )
        XCTAssertEqual(
            RuntimeLocator.installationManifest(root: backup)?.runtimeVersion,
            "new-runtime"
        )
    }
}
