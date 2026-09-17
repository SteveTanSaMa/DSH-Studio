//
//  RuntimeReleaseCatalog.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import Foundation

/// The signed index of immutable Runtime artifacts.
///
/// The Runtime Builder creates this file from the two architecture-specific
/// artifact manifests. DSH Studio verifies it before using any release data, so
/// users never resolve npm `latest`, execute a remote install script, or trust
/// mutable update JSON.
public struct RuntimeReleaseCatalog: Codable, Equatable, Sendable {
    /// The catalog schema this app accepts; other versions are treated as unavailable.
    public static let currentSchemaVersion = 1

    /// Schema version of the published catalog.
    public let schemaVersion: Int
    /// Runtime version the whole catalog describes; every entry must match it.
    public let runtimeVersion: String
    /// One release per supported architecture.
    public let releases: [RuntimeReleaseDescriptor]

    /// Creates a catalog.
    ///
    /// - Parameters:
    ///   - schemaVersion: Schema to record; defaults to ``currentSchemaVersion``.
    ///   - runtimeVersion: Runtime version shared by every release.
    ///   - releases: Releases, one per architecture.
    public init(
        schemaVersion: Int = currentSchemaVersion,
        runtimeVersion: String,
        releases: [RuntimeReleaseDescriptor]
    ) {
        self.schemaVersion = schemaVersion
        self.runtimeVersion = runtimeVersion
        self.releases = releases
    }

    /// Returns the release for one architecture after validating the catalog.
    ///
    /// Every invariant and URL restriction must hold; a malformed or cross-version
    /// entry is treated as unavailable.
    public func release(for architecture: String) -> RuntimeReleaseDescriptor? {
        guard schemaVersion == Self.currentSchemaVersion,
              RuntimeLocator.isSafeRuntimeVersion(runtimeVersion) else {
            return nil
        }

        guard releases.filter({ $0.architecture == architecture }).count == 1,
              let release = releases.first(where: { $0.architecture == architecture }),
              release.runtimeVersion == runtimeVersion,
              let artifact = release.artifact,
              artifact.runtimeVersion == runtimeVersion,
              artifact.architecture == architecture,
              !release.nodeVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !release.harnessVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !release.pnpmVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              isValidSHA256(release.nodeArchiveSHA256),
              !release.harnessPackageIntegrity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !release.pnpmPackageIntegrity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              release.dataFormat == nil || release.dataFormat?.isValid == true,
              isValidSHA256(artifact.sha256),
              Self.isTrustedArtifactURL(artifact.url, runtimeVersion: runtimeVersion, architecture: architecture) else {
            return nil
        }
        return release
    }

    /// Loads the bundled catalog and returns the release for an architecture.
    ///
    /// - Parameters:
    ///   - bundle: Bundle containing `RuntimeManifest/runtime-release.json`.
    ///   - architecture: Architecture to resolve; defaults to this host's.
    /// - Returns: The verified release, or `nil` when the catalog is missing or the
    ///   entry fails validation.
    public static func load(
        bundle: Bundle = .main,
        architecture: String = RuntimeLocator.architectureDirectory()
    ) -> RuntimeReleaseDescriptor? {
        guard let catalog = try? loadCatalog(bundle: bundle) else {
            return nil
        }
        return catalog.release(for: architecture)
    }

    /// Loads the catalog shipped inside the app bundle.
    ///
    /// - Parameter bundle: Bundle containing the catalog resource.
    /// - Returns: The decoded catalog, or `nil` when the resource is absent.
    /// - Throws: A `DecodingError` when the bundled catalog is malformed.
    public static func loadCatalog(bundle: Bundle = .main) throws -> Self? {
        guard let url = bundle.url(
            forResource: "runtime-release",
            withExtension: "json",
            subdirectory: "RuntimeManifest"
        ), let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    /// Decodes a catalog from signed payload bytes.
    ///
    /// - Parameter data: JSON bytes of the catalog, already signature-checked by the
    ///   caller.
    /// - Returns: The decoded catalog.
    /// - Throws: A `DecodingError` when the payload does not match the schema.
    public static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

    /// Whether an artifact URL is the expected release asset for a version.
    ///
    /// Requires HTTPS on `github.com`, no credentials and no explicit port, and the
    /// exact path of the Runtime repository's release asset.
    ///
    /// - Parameters:
    ///   - url: Artifact URL taken from the catalog.
    ///   - runtimeVersion: Runtime version the asset must belong to.
    ///   - architecture: Architecture the asset must target.
    /// - Returns: `true` when the URL is the expected trusted asset.
    public static func isTrustedArtifactURL(
        _ url: URL,
        runtimeVersion: String,
        architecture: String
    ) -> Bool {
        guard url.scheme == "https",
              url.host == "github.com",
              url.user == nil,
              url.password == nil,
              url.port == nil else {
            return false
        }

        let expectedPath = "/SteveTanSaMa/DSH-Studio-Runtime/releases/download/runtime-\(runtimeVersion)/dsh-runtime-\(runtimeVersion)-\(architecture).tar.gz"
        return url.path == expectedPath
    }

    /// Whether a URL is the expected signed-catalog location.
    ///
    /// - Parameter url: URL to test.
    /// - Returns: `true` when the URL is the Runtime repository's catalog asset.
    public static func isTrustedCatalogURL(_ url: URL) -> Bool {
        guard url.scheme == "https",
              url.host == "github.com",
              url.user == nil,
              url.password == nil,
              url.port == nil else {
            return false
        }
        return url.path == "/SteveTanSaMa/DSH-Studio-Runtime/releases/download/runtime-catalog/runtime-catalog.signed.json"
    }

    private func isValidSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }
}
