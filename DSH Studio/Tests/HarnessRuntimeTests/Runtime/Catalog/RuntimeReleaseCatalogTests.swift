//
//  RuntimeReleaseCatalogTests.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import Foundation
import XCTest
@testable import DeepSeekRuntime

/// Verifies that only the app's own immutable Runtime release assets can be
/// selected from a catalog.
final class RuntimeReleaseCatalogTests: XCTestCase {
    private let architecture = "darwin-arm64"
    private let runtimeVersion = "2026.08.20.test"

    func testCatalogSelectsMatchingTrustedArtifact() throws {
        let catalog = try makeCatalog()

        let release = catalog.release(for: architecture)

        XCTAssertEqual(release?.runtimeVersion, runtimeVersion)
        XCTAssertEqual(release?.artifact?.architecture, architecture)
    }

    func testCatalogRejectsNonGitHubArtifactURL() throws {
        var release = try makeRelease()
        release = RuntimeReleaseDescriptor(
            architecture: release.architecture,
            nodeVersion: release.nodeVersion,
            harnessVersion: release.harnessVersion,
            pnpmVersion: release.pnpmVersion,
            nodeArchiveSHA256: release.nodeArchiveSHA256,
            harnessPackageIntegrity: release.harnessPackageIntegrity,
            pnpmPackageIntegrity: release.pnpmPackageIntegrity,
            runtimeVersion: release.runtimeVersion,
            artifact: RuntimeArtifactDescriptor(
                runtimeVersion: runtimeVersion,
                architecture: architecture,
                url: URL(string: "https://example.com/runtime.tar.gz")!,
                sha256: String(repeating: "a", count: 64)
            )
        )
        let catalog = RuntimeReleaseCatalog(runtimeVersion: runtimeVersion, releases: [release])

        XCTAssertNil(catalog.release(for: architecture))
    }

    func testCatalogRejectsMismatchedArtifactVersion() throws {
        let release = try makeRelease()
        let mismatchedArtifact = RuntimeArtifactDescriptor(
            runtimeVersion: "2026.08.21.test",
            architecture: architecture,
            url: URL(string: "https://github.com/SteveTanSaMa/DSH-Studio-Runtime/releases/download/runtime-\(runtimeVersion)/dsh-runtime-\(runtimeVersion)-\(architecture).tar.gz")!,
            sha256: String(repeating: "b", count: 64)
        )
        let mismatchedRelease = RuntimeReleaseDescriptor(
            architecture: release.architecture,
            nodeVersion: release.nodeVersion,
            harnessVersion: release.harnessVersion,
            pnpmVersion: release.pnpmVersion,
            nodeArchiveSHA256: release.nodeArchiveSHA256,
            harnessPackageIntegrity: release.harnessPackageIntegrity,
            pnpmPackageIntegrity: release.pnpmPackageIntegrity,
            runtimeVersion: release.runtimeVersion,
            artifact: mismatchedArtifact
        )
        let catalog = RuntimeReleaseCatalog(runtimeVersion: runtimeVersion, releases: [mismatchedRelease])

        XCTAssertNil(catalog.release(for: architecture))
    }

    func testCatalogRejectsUnsafeRuntimeVersion() throws {
        let release = RuntimeReleaseDescriptor(
            architecture: architecture,
            nodeVersion: RuntimeRelease.nodeVersion,
            harnessVersion: RuntimeRelease.harnessVersion,
            pnpmVersion: RuntimeRelease.pnpmVersion,
            nodeArchiveSHA256: String(repeating: "c", count: 64),
            harnessPackageIntegrity: RuntimeRelease.harnessPackageIntegrity,
            pnpmPackageIntegrity: RuntimeRelease.pnpmPackageIntegrity,
            runtimeVersion: "..",
            artifact: RuntimeArtifactDescriptor(
                runtimeVersion: "..",
                architecture: architecture,
                url: URL(string: "https://github.com/SteveTanSaMa/DSH-Studio-Runtime/releases/download/runtime-../dsh-runtime-..-darwin-arm64.tar.gz")!,
                sha256: String(repeating: "a", count: 64)
            )
        )
        let catalog = RuntimeReleaseCatalog(runtimeVersion: "..", releases: [release])

        XCTAssertNil(catalog.release(for: architecture))
    }

    private func makeCatalog() throws -> RuntimeReleaseCatalog {
        RuntimeReleaseCatalog(runtimeVersion: runtimeVersion, releases: [try makeRelease()])
    }

    private func makeRelease() throws -> RuntimeReleaseDescriptor {
        RuntimeReleaseDescriptor(
            architecture: architecture,
            nodeVersion: RuntimeRelease.nodeVersion,
            harnessVersion: RuntimeRelease.harnessVersion,
            pnpmVersion: RuntimeRelease.pnpmVersion,
            nodeArchiveSHA256: String(repeating: "c", count: 64),
            harnessPackageIntegrity: RuntimeRelease.harnessPackageIntegrity,
            pnpmPackageIntegrity: RuntimeRelease.pnpmPackageIntegrity,
            runtimeVersion: runtimeVersion,
            artifact: RuntimeArtifactDescriptor(
                runtimeVersion: runtimeVersion,
                architecture: architecture,
                url: URL(string: "https://github.com/SteveTanSaMa/DSH-Studio-Runtime/releases/download/runtime-\(runtimeVersion)/dsh-runtime-\(runtimeVersion)-\(architecture).tar.gz")!,
                sha256: String(repeating: "a", count: 64)
            )
        )
    }
}
