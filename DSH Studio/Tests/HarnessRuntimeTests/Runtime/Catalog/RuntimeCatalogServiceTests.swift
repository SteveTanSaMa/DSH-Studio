//
//  RuntimeCatalogServiceTests.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/21.
//

import CryptoKit
import Foundation
import XCTest

@testable import DeepSeekRuntime

final class RuntimeCatalogServiceTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepSeekStudio.RuntimeCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testVerifiedRemoteCatalogIsSelectedAndCached() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let catalog = try makeCatalog(runtimeVersion: "2026.08.21.1")
        let envelope = try RuntimeSignedCatalog.signed(
            catalog: catalog,
            using: privateKey,
            keyID: RuntimeCatalogTrust.keyID
        )
        let data = try JSONEncoder().encode(envelope)
        let fetcher = FixtureCatalogFetcher(result: .success(data))
        let service = RuntimeCatalogService(
            supportDirectory: temporaryRoot,
            architecture: "darwin-arm64",
            publicKeyData: privateKey.publicKey.rawRepresentation,
            fetcher: fetcher
        )

        let resolution = try await service.resolve()

        XCTAssertEqual(resolution.source, .remote)
        XCTAssertEqual(resolution.release.runtimeVersion, "2026.08.21.1")
        XCTAssertEqual(fetcher.fetchCount, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: temporaryRoot
                    .appendingPathComponent("RuntimeManifest/runtime-catalog.signed.json")
                    .path
            )
        )
    }

    func testFailedRemoteFetchUsesPreviouslyVerifiedCache() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let catalog = try makeCatalog(runtimeVersion: "2026.08.21.2")
        let envelope = try RuntimeSignedCatalog.signed(
            catalog: catalog,
            using: privateKey,
            keyID: RuntimeCatalogTrust.keyID
        )
        let data = try JSONEncoder().encode(envelope)

        let firstService = RuntimeCatalogService(
            supportDirectory: temporaryRoot,
            architecture: "darwin-arm64",
            publicKeyData: privateKey.publicKey.rawRepresentation,
            fetcher: FixtureCatalogFetcher(result: .success(data))
        )
        _ = try await firstService.resolve()

        let secondService = RuntimeCatalogService(
            supportDirectory: temporaryRoot,
            architecture: "darwin-arm64",
            publicKeyData: privateKey.publicKey.rawRepresentation,
            fetcher: FixtureCatalogFetcher(result: .failure(RuntimeCatalogError.downloadFailed("offline")))
        )

        let resolution = try await secondService.resolve()

        XCTAssertEqual(resolution.source, .cache)
        XCTAssertEqual(resolution.release.runtimeVersion, "2026.08.21.2")
    }

    func testSignedResolutionDoesNotUseUnsignedBundledCatalog() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let bundledCatalog = try makeCatalog(runtimeVersion: "2026.08.21.9")
        let bundledBundle = try makeBundle(with: bundledCatalog)
        let service = RuntimeCatalogService(
            supportDirectory: temporaryRoot,
            bundle: bundledBundle,
            architecture: "darwin-arm64",
            publicKeyData: privateKey.publicKey.rawRepresentation,
            fetcher: FixtureCatalogFetcher(result: .failure(RuntimeCatalogError.downloadFailed("offline")))
        )

        do {
            _ = try await service.signedResolution()
            XCTFail("unsigned bundled catalog must not be treated as a signed latest release")
        } catch let error as RuntimeCatalogError {
            XCTAssertEqual(error, .unavailable)
        }
    }

    func testConflictingRemoteCatalogCannotReplaceKnownSameVersionRelease() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let knownCatalog = try makeCatalog(
            runtimeVersion: "2026.08.21.4",
            artifactSHA256: String(repeating: "b", count: 64)
        )
        let knownEnvelope = try RuntimeSignedCatalog.signed(
            catalog: knownCatalog,
            using: privateKey,
            keyID: RuntimeCatalogTrust.keyID
        )
        let knownData = try JSONEncoder().encode(knownEnvelope)
        let firstService = RuntimeCatalogService(
            supportDirectory: temporaryRoot,
            architecture: "darwin-arm64",
            publicKeyData: privateKey.publicKey.rawRepresentation,
            fetcher: FixtureCatalogFetcher(result: .success(knownData))
        )
        _ = try await firstService.resolve()

        let conflictingCatalog = try makeCatalog(
            runtimeVersion: "2026.08.21.4",
            artifactSHA256: String(repeating: "c", count: 64)
        )
        let conflictingEnvelope = try RuntimeSignedCatalog.signed(
            catalog: conflictingCatalog,
            using: privateKey,
            keyID: RuntimeCatalogTrust.keyID
        )
        let secondService = RuntimeCatalogService(
            supportDirectory: temporaryRoot,
            architecture: "darwin-arm64",
            publicKeyData: privateKey.publicKey.rawRepresentation,
            fetcher: FixtureCatalogFetcher(
                result: .success(try JSONEncoder().encode(conflictingEnvelope))
            )
        )

        let resolution = try await secondService.resolve()

        XCTAssertEqual(resolution.source, .cache)
        XCTAssertEqual(resolution.release.artifact?.sha256, String(repeating: "b", count: 64))
    }

    func testConflictingCacheCannotReplaceBundledSameVersionRelease() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let bundledCatalog = try makeCatalog(
            runtimeVersion: "2026.08.21.5",
            artifactSHA256: String(repeating: "b", count: 64)
        )
        let conflictingCache = try makeCatalog(
            runtimeVersion: "2026.08.21.5",
            artifactSHA256: String(repeating: "c", count: 64)
        )
        let cachedEnvelope = try RuntimeSignedCatalog.signed(
            catalog: conflictingCache,
            using: privateKey,
            keyID: RuntimeCatalogTrust.keyID
        )
        let cacheURL = temporaryRoot
            .appendingPathComponent("RuntimeManifest", isDirectory: true)
            .appendingPathComponent("runtime-catalog.signed.json")
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(cachedEnvelope).write(to: cacheURL, options: .atomic)

        let bundledBundle = try makeBundle(with: bundledCatalog)
        let service = RuntimeCatalogService(
            supportDirectory: temporaryRoot,
            bundle: bundledBundle,
            architecture: "darwin-arm64",
            publicKeyData: privateKey.publicKey.rawRepresentation,
            fetcher: FixtureCatalogFetcher(result: .failure(RuntimeCatalogError.downloadFailed("offline")))
        )

        let resolution = try await service.resolve()

        XCTAssertEqual(resolution.source, .bundled)
        XCTAssertEqual(resolution.release.artifact?.sha256, String(repeating: "b", count: 64))
    }

    func testTamperedEnvelopeCannotBeVerified() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let catalog = try makeCatalog(runtimeVersion: "2026.08.21.3")
        let envelope = try RuntimeSignedCatalog.signed(
            catalog: catalog,
            using: privateKey,
            keyID: RuntimeCatalogTrust.keyID
        )
        var tamperedPayload = Data(base64Encoded: envelope.payload)!
        tamperedPayload.append(Data("tampered".utf8))
        let tampered = RuntimeSignedCatalog(
            keyID: envelope.keyID,
            payload: tamperedPayload.base64EncodedString(),
            signature: envelope.signature
        )

        XCTAssertThrowsError(
            try tampered.verifiedCatalog(publicKeyData: privateKey.publicKey.rawRepresentation)
        ) { error in
            XCTAssertEqual(error as? RuntimeCatalogError, .signatureInvalid)
        }
    }

    private func makeCatalog(
        runtimeVersion: String,
        artifactSHA256: String = String(repeating: "b", count: 64)
    ) throws -> RuntimeReleaseCatalog {
        let release = RuntimeReleaseDescriptor(
            architecture: "darwin-arm64",
            nodeVersion: RuntimeRelease.nodeVersion,
            harnessVersion: RuntimeRelease.harnessVersion,
            pnpmVersion: RuntimeRelease.pnpmVersion,
            nodeArchiveSHA256: String(repeating: "a", count: 64),
            harnessPackageIntegrity: RuntimeRelease.harnessPackageIntegrity,
            pnpmPackageIntegrity: RuntimeRelease.pnpmPackageIntegrity,
            runtimeVersion: runtimeVersion,
            artifact: RuntimeArtifactDescriptor(
                runtimeVersion: runtimeVersion,
                architecture: "darwin-arm64",
                url: URL(
                    string: "https://github.com/SteveTanSaMa/DSH-Studio-Runtime/releases/download/runtime-\(runtimeVersion)/dsh-runtime-\(runtimeVersion)-darwin-arm64.tar.gz"
                )!,
                sha256: artifactSHA256
            ),
            dataFormat: RuntimeDataFormatDescriptor(id: "sqlite-v2")
        )
        return RuntimeReleaseCatalog(runtimeVersion: runtimeVersion, releases: [release])
    }

    private func makeBundle(with catalog: RuntimeReleaseCatalog) throws -> Bundle {
        let bundleDirectory = temporaryRoot.appendingPathComponent("Bundle", isDirectory: true)
        let manifestDirectory = bundleDirectory.appendingPathComponent("RuntimeManifest", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
        let info = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict></dict></plist>"#
        try Data(info.utf8).write(to: bundleDirectory.appendingPathComponent("Info.plist"), options: .atomic)
        try JSONEncoder().encode(catalog).write(
            to: manifestDirectory.appendingPathComponent("runtime-release.json"),
            options: .atomic
        )
        return try XCTUnwrap(Bundle(path: bundleDirectory.path))
    }
}

private final class FixtureCatalogFetcher: RuntimeCatalogFetching, @unchecked Sendable {
    private let result: Result<Data, Error>
    private(set) var fetchCount = 0

    init(result: Result<Data, Error>) {
        self.result = result
    }

    func fetch(from url: URL) async throws -> Data {
        fetchCount += 1
        return try result.get()
    }
}
