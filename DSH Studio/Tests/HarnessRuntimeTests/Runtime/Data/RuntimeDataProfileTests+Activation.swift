import Foundation
import XCTest

@testable import DeepSeekRuntime

extension RuntimeDataProfileTests {
    func testActivationPersistsRuntimeAndDataProfilePair() throws {
        let store = RuntimeDataProfileStore(supportDirectory: temporaryRoot)
        let profile = try store.ensureLegacyProfile(
            homeURL: temporaryRoot.appendingPathComponent("legacy", isDirectory: true),
            dataFormatID: "sqlite-v1"
        )
        let manifest = RuntimeInstallationManifest(
            runtimeVersion: "rc7-runtime",
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            harnessVersion: "0.1.0-rc.7",
            nodeSHA256: "node-sha",
            harnessPackageIntegrity: "harness-integrity",
            dataFormat: RuntimeDataFormatDescriptor(id: "sqlite-v1")
        )

        let activated = try store.activate(profile: profile, runtimeManifest: manifest)

        XCTAssertEqual(activated.dataFormatID, "sqlite-v1")
        XCTAssertEqual(store.activeState(), RuntimeActiveState(
            profileID: profile.id,
            runtimeVersion: "rc7-runtime",
            dataFormatID: "sqlite-v1"
        ))
        XCTAssertEqual(store.activeProfile(), activated)
        XCTAssertEqual(store.dataFormatID(forProfileID: profile.id), "sqlite-v1")
    }

    func testDataFormatLookupDoesNotTrustActiveStateWhenProfileMetadataIsMissing() throws {
        let store = RuntimeDataProfileStore(supportDirectory: temporaryRoot)
        let profile = try store.ensureLegacyProfile(
            homeURL: temporaryRoot.appendingPathComponent("legacy", isDirectory: true),
            dataFormatID: "sqlite-v1"
        )
        let manifest = RuntimeInstallationManifest(
            runtimeVersion: "rc7-runtime",
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            harnessVersion: "0.1.0-rc.7",
            nodeSHA256: "node-sha",
            harnessPackageIntegrity: "harness-integrity",
            dataFormat: RuntimeDataFormatDescriptor(id: "sqlite-v1")
        )
        _ = try store.activate(profile: profile, runtimeManifest: manifest)

        let profileFile = store.profilesDirectory
            .appendingPathComponent(profile.id, isDirectory: true)
            .appendingPathComponent("profile.json", isDirectory: false)
        try FileManager.default.removeItem(at: profileFile)

        XCTAssertNil(store.dataFormatID(forProfileID: profile.id))
        XCTAssertEqual(store.activeState()?.dataFormatID, "sqlite-v1")
    }

    func testActivationRetainsPreviousRuntimeVersionForRollback() throws {
        let store = RuntimeDataProfileStore(supportDirectory: temporaryRoot)
        let profile = try store.ensureLegacyProfile(
            homeURL: temporaryRoot.appendingPathComponent("legacy", isDirectory: true),
            dataFormatID: "sqlite-v1"
        )
        let firstManifest = RuntimeInstallationManifest(
            runtimeVersion: "rc7-runtime",
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            harnessVersion: "0.1.0-rc.7",
            nodeSHA256: "node-sha-1",
            harnessPackageIntegrity: "harness-integrity-1",
            dataFormat: RuntimeDataFormatDescriptor(id: "sqlite-v1")
        )
        let secondManifest = RuntimeInstallationManifest(
            runtimeVersion: "rc8-runtime",
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            harnessVersion: "0.1.0-rc.8",
            nodeSHA256: "node-sha-2",
            harnessPackageIntegrity: "harness-integrity-2",
            dataFormat: RuntimeDataFormatDescriptor(id: "sqlite-v1")
        )

        _ = try store.activate(profile: profile, runtimeManifest: firstManifest)
        _ = try store.activate(profile: profile, runtimeManifest: secondManifest)

        XCTAssertEqual(store.activeState()?.runtimeVersion, "rc8-runtime")
        XCTAssertEqual(store.activeState()?.previousRuntimeVersion, "rc7-runtime")
    }

    func testActivationRetainsPreviousProfileForRuntimeRollback() throws {
        let store = RuntimeDataProfileStore(supportDirectory: temporaryRoot)
        let oldProfile = try store.ensureLegacyProfile(
            homeURL: temporaryRoot.appendingPathComponent("old-data", isDirectory: true),
            dataFormatID: "sqlite-v1"
        )
        let newProfile = try store.createProfile(name: "Harness rc8", dataFormatID: "sqlite-v2")
        let oldManifest = RuntimeInstallationManifest(
            runtimeVersion: "rc7-runtime",
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            harnessVersion: "0.1.0-rc.7",
            nodeSHA256: "node-sha-1",
            harnessPackageIntegrity: "harness-integrity-1",
            dataFormat: RuntimeDataFormatDescriptor(id: "sqlite-v1")
        )
        let newManifest = RuntimeInstallationManifest(
            runtimeVersion: "rc8-runtime",
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            harnessVersion: "0.1.0-rc.8",
            nodeSHA256: "node-sha-2",
            harnessPackageIntegrity: "harness-integrity-2",
            dataFormat: RuntimeDataFormatDescriptor(id: "sqlite-v2")
        )

        _ = try store.activate(profile: oldProfile, runtimeManifest: oldManifest)
        _ = try store.activate(profile: newProfile, runtimeManifest: newManifest)

        XCTAssertEqual(store.activeState()?.previousProfileID, oldProfile.id)
        XCTAssertEqual(store.previousProfile(), oldProfile)
    }

    func testUnknownRuntimeAndLegacyDataCanPersistActivePointerWithoutInferringFormat() throws {
        let store = RuntimeDataProfileStore(supportDirectory: temporaryRoot)
        let home = temporaryRoot.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: home.appendingPathComponent("database.sqlite"))
        let profile = try store.ensureLegacyProfile(homeURL: home)
        let manifest = RuntimeInstallationManifest(
            runtimeVersion: "legacy-runtime",
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            harnessVersion: "0.1.0-rc.6",
            nodeSHA256: "node-sha",
            harnessPackageIntegrity: "harness-integrity",
            dataFormat: nil
        )

        let activated = try store.activate(profile: profile, runtimeManifest: manifest)

        XCTAssertNil(activated.dataFormatID)
        XCTAssertEqual(store.activeState()?.runtimeVersion, "legacy-runtime")
        XCTAssertNil(store.activeState()?.dataFormatID)
    }

    func testActivationRejectsIncompatibleProfileAndRuntime() throws {
        let store = RuntimeDataProfileStore(supportDirectory: temporaryRoot)
        let profile = try store.ensureLegacyProfile(
            homeURL: temporaryRoot.appendingPathComponent("rc7-data", isDirectory: true),
            dataFormatID: "sqlite-v1"
        )
        let manifest = RuntimeInstallationManifest(
            runtimeVersion: "rc8-runtime",
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            harnessVersion: "0.1.0-rc.8",
            nodeSHA256: "node-sha",
            harnessPackageIntegrity: "harness-integrity",
            dataFormat: RuntimeDataFormatDescriptor(id: "sqlite-v2")
        )

        XCTAssertThrowsError(try store.activate(profile: profile, runtimeManifest: manifest)) { error in
            XCTAssertEqual(
                error as? RuntimeDataProfileStoreError,
                .dataFormatMismatch(profile: "sqlite-v1", runtime: "sqlite-v2")
            )
        }
        XCTAssertNil(store.activeState())
    }

    func testEmptyLegacyHomeCanReceiveItsFirstRuntimeFormat() throws {
        let store = RuntimeDataProfileStore(supportDirectory: temporaryRoot)
        let profile = try store.ensureLegacyProfile(
            homeURL: temporaryRoot.appendingPathComponent("new-dsh-home", isDirectory: true)
        )
        let manifest = RuntimeInstallationManifest(
            runtimeVersion: "rc8-runtime",
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            harnessVersion: "0.1.0-rc.8",
            nodeSHA256: "node-sha",
            harnessPackageIntegrity: "harness-integrity",
            dataFormat: RuntimeDataFormatDescriptor(id: "sqlite-v2")
        )

        let activated = try store.activate(profile: profile, runtimeManifest: manifest)

        XCTAssertEqual(activated.dataFormatID, "sqlite-v2")
        XCTAssertEqual(store.activeState()?.dataFormatID, "sqlite-v2")
    }

    func testPreLaunchEmptyHomeCanReceiveFormatAfterHarnessCreatesFiles() throws {
        let store = RuntimeDataProfileStore(supportDirectory: temporaryRoot)
        let home = temporaryRoot.appendingPathComponent("new-dsh-home", isDirectory: true)
        let profile = try store.ensureLegacyProfile(homeURL: home)
        let manifest = RuntimeInstallationManifest(
            runtimeVersion: "rc8-runtime",
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            harnessVersion: "0.1.0-rc.8",
            nodeSHA256: "node-sha",
            harnessPackageIntegrity: "harness-integrity",
            dataFormat: RuntimeDataFormatDescriptor(id: "sqlite-v2")
        )

        // Simulate Harness initialization between process launch and the
        // health-check callback.
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: home.appendingPathComponent("workspace.json"))

        let activated = try store.activate(
            profile: profile,
            runtimeManifest: manifest,
            dataHomeWasEmptyAtLaunch: true
        )

        XCTAssertEqual(activated.dataFormatID, "sqlite-v2")
        XCTAssertEqual(store.activeState()?.dataFormatID, "sqlite-v2")
    }

    func testNonEmptyUnknownLegacyHomeCannotReceiveAFormatByInference() throws {
        let store = RuntimeDataProfileStore(supportDirectory: temporaryRoot)
        let home = temporaryRoot.appendingPathComponent("old-dsh-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: home.appendingPathComponent("database.sqlite"))
        let profile = try store.ensureLegacyProfile(homeURL: home)
        let manifest = RuntimeInstallationManifest(
            runtimeVersion: "rc8-runtime",
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            harnessVersion: "0.1.0-rc.8",
            nodeSHA256: "node-sha",
            harnessPackageIntegrity: "harness-integrity",
            dataFormat: RuntimeDataFormatDescriptor(id: "sqlite-v2")
        )

        XCTAssertThrowsError(try store.activate(profile: profile, runtimeManifest: manifest)) { error in
            XCTAssertEqual(error as? RuntimeDataProfileStoreError, .dataFormatUnknown)
        }
    }
}
