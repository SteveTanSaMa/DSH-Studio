//
//  RuntimeDataCompatibilityTests.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/21.
//

import XCTest
@testable import DeepSeekRuntime

/// Guards the data-contract rules that decide whether a Runtime may take over.
///
/// The tests pin the fail-closed behavior: an unknown format must never be read as
/// compatible, and a format is never inferred from the installed Runtime.
final class RuntimeDataCompatibilityTests: XCTestCase {
    /// The same format identifier is compatible.
    func testMatchingFormatIsCompatible() {
        let format = RuntimeDataFormatDescriptor(
            id: "sqlite-v2",
            compatibleWith: ["sqlite-v1"]
        )

        XCTAssertEqual(format.compatibility(with: "sqlite-v2"), .compatible)
        XCTAssertEqual(format.compatibility(with: "sqlite-v1"), .compatible)
    }

    /// Without a stored format the verdict is unknown, not compatible.
    func testMissingCurrentFormatIsUnknown() {
        let format = RuntimeDataFormatDescriptor(id: "sqlite-v2")

        XCTAssertEqual(format.compatibility(with: nil), .unknown)
    }

    /// A different format with no migration offered is incompatible.
    func testDifferentFormatWithoutMigrationIsIncompatible() {
        let format = RuntimeDataFormatDescriptor(id: "sqlite-v2")

        XCTAssertEqual(format.compatibility(with: "sqlite-v1"), .incompatible)
    }

    /// A different format with a migration offered requires the migration.
    func testDifferentFormatWithMigrationRequiresMigration() {
        let format = RuntimeDataFormatDescriptor(
            id: "sqlite-v2",
            migration: "harness-migrate-v1-to-v2"
        )

        XCTAssertEqual(format.compatibility(with: "sqlite-v1"), .requiresMigration)
    }

    /// A blank format identifier fails validation.
    func testEmptyFormatIDIsInvalid() {
        XCTAssertFalse(RuntimeDataFormatDescriptor(id: " ").isValid)
        XCTAssertTrue(RuntimeDataFormatDescriptor(id: "sqlite-v2").isValid)
    }

    /// The active profile's format decides, not the installed Runtime's.
    func testStatusUsesActiveDataProfileFormatBeforeInstalledRuntimeFormat() {
        let release = RuntimeReleaseDescriptor(
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            harnessVersion: "0.1.0-rc.8",
            pnpmVersion: "11.7.0",
            nodeArchiveSHA256: "node-sha",
            harnessPackageIntegrity: "harness-integrity",
            pnpmPackageIntegrity: "pnpm-integrity",
            runtimeVersion: "rc8-runtime",
            dataFormat: RuntimeDataFormatDescriptor(id: "sqlite-v2")
        )
        let installed = RuntimeInstallationManifest(
            runtimeVersion: "rc7-runtime",
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            harnessVersion: "0.1.0-rc.7",
            nodeSHA256: "old-node-sha",
            harnessPackageIntegrity: "old-harness-integrity",
            dataFormat: RuntimeDataFormatDescriptor(id: "sqlite-v1")
        )
        let status = RuntimeVersionStatus(
            kind: .updateAvailable,
            installed: installed,
            available: release,
            activeProfileID: "legacy-profile",
            activeDataFormatID: "sqlite-v2",
            rollbackAvailable: false
        )

        XCTAssertEqual(status.dataCompatibility, .compatible)
    }

    /// A format without a profile identity is not trusted.
    func testStatusDoesNotTrustFormatWithoutActiveProfileIdentity() {
        let release = RuntimeReleaseDescriptor(
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            harnessVersion: "0.1.0-rc.8",
            pnpmVersion: "11.7.0",
            nodeArchiveSHA256: "node-sha",
            harnessPackageIntegrity: "harness-integrity",
            pnpmPackageIntegrity: "pnpm-integrity",
            runtimeVersion: "rc8-runtime",
            dataFormat: RuntimeDataFormatDescriptor(id: "sqlite-v2")
        )
        let status = RuntimeVersionStatus(
            kind: .updateAvailable,
            installed: nil,
            available: release,
            activeProfileID: nil,
            activeDataFormatID: "sqlite-v2",
            rollbackAvailable: false
        )

        XCTAssertEqual(status.dataCompatibility, .unknown)
    }

    /// An unknown profile keeps an unknown verdict despite the Runtime's format.
    func testStatusDoesNotInferUnknownProfileFromInstalledRuntimeFormat() {
        let release = RuntimeReleaseDescriptor(
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            harnessVersion: "0.1.0-rc.8",
            pnpmVersion: "11.7.0",
            nodeArchiveSHA256: "node-sha",
            harnessPackageIntegrity: "harness-integrity",
            pnpmPackageIntegrity: "pnpm-integrity",
            runtimeVersion: "rc8-runtime",
            dataFormat: RuntimeDataFormatDescriptor(id: "sqlite-v2")
        )
        let installed = RuntimeInstallationManifest(
            runtimeVersion: "rc7-runtime",
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            harnessVersion: "0.1.0-rc.7",
            nodeSHA256: "old-node-sha",
            harnessPackageIntegrity: "old-harness-integrity",
            dataFormat: RuntimeDataFormatDescriptor(id: "sqlite-v1")
        )
        let status = RuntimeVersionStatus(
            kind: .updateAvailable,
            installed: installed,
            available: release,
            activeProfileID: "legacy-profile",
            activeDataFormatID: nil,
            rollbackAvailable: false
        )

        XCTAssertEqual(status.dataCompatibility, .unknown)
    }

    /// A missing profile keeps an unknown verdict despite the Runtime's format.
    func testStatusDoesNotInferMissingProfileFromInstalledRuntimeFormat() {
        let release = RuntimeReleaseDescriptor(
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            harnessVersion: "0.1.0-rc.8",
            pnpmVersion: "11.7.0",
            nodeArchiveSHA256: "node-sha",
            harnessPackageIntegrity: "harness-integrity",
            pnpmPackageIntegrity: "pnpm-integrity",
            runtimeVersion: "rc8-runtime",
            dataFormat: RuntimeDataFormatDescriptor(id: "sqlite-v2")
        )
        let installed = RuntimeInstallationManifest(
            runtimeVersion: "rc7-runtime",
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            harnessVersion: "0.1.0-rc.7",
            nodeSHA256: "old-node-sha",
            harnessPackageIntegrity: "old-harness-integrity",
            dataFormat: RuntimeDataFormatDescriptor(id: "sqlite-v2")
        )
        let status = RuntimeVersionStatus(
            kind: .updateAvailable,
            installed: installed,
            available: release,
            activeProfileID: nil,
            activeDataFormatID: nil,
            rollbackAvailable: false
        )

        XCTAssertEqual(status.dataCompatibility, .unknown)
    }
}
