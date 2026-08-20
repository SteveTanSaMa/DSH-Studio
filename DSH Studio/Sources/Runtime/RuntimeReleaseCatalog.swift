//
//  RuntimeReleaseCatalog.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import Foundation

/// The signed-in-app index of immutable Runtime artifacts.
///
/// The Builder creates this file from the two architecture-specific artifact
/// manifests. It is bundled with the app, so users never resolve npm
/// `latest`, execute a remote install script, or trust mutable update JSON.
public struct RuntimeReleaseCatalog: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let runtimeVersion: String
    public let releases: [RuntimeReleaseDescriptor]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        runtimeVersion: String,
        releases: [RuntimeReleaseDescriptor]
    ) {
        self.schemaVersion = schemaVersion
        self.runtimeVersion = runtimeVersion
        self.releases = releases
    }

    /// Returns a release only when all catalog invariants and URL restrictions
    /// hold. A malformed or cross-version entry is treated as unavailable.
    public func release(for architecture: String) -> RuntimeReleaseDescriptor? {
        guard schemaVersion == Self.currentSchemaVersion,
              !runtimeVersion.isEmpty else {
            return nil
        }

        guard releases.filter({ $0.architecture == architecture }).count == 1,
              let release = releases.first(where: { $0.architecture == architecture }),
              release.runtimeVersion == runtimeVersion,
              let artifact = release.artifact,
              artifact.runtimeVersion == runtimeVersion,
              artifact.architecture == architecture,
              isValidSHA256(artifact.sha256),
              Self.isTrustedArtifactURL(artifact.url, runtimeVersion: runtimeVersion, architecture: architecture) else {
            return nil
        }
        return release
    }

    public static func load(
        bundle: Bundle = .main,
        architecture: String = RuntimeLocator.architectureDirectory()
    ) -> RuntimeReleaseDescriptor? {
        guard let url = bundle.url(
            forResource: "runtime-release",
            withExtension: "json",
            subdirectory: "RuntimeManifest"
        ), let data = try? Data(contentsOf: url) else {
            return nil
        }
        return (try? JSONDecoder().decode(Self.self, from: data))?.release(for: architecture)
    }

    public static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

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

        let expectedPath = "/SteveTanSaMa/DSH-Studio/releases/download/runtime-\(runtimeVersion)/dsh-runtime-\(runtimeVersion)-\(architecture).tar.gz"
        return url.path == expectedPath
    }

    private func isValidSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }
}
