//
//  RuntimeRelease.swift
//  DSH Studio
//

import Foundation

/// Fixed release inputs used by the verified online Runtime installer.
///
/// These values intentionally avoid mutable "latest" URLs and remote install
/// scripts. Every network request can therefore be checked against a known
/// host, version, integrity value, and archive checksum.
public enum RuntimeRelease {
    /// Runtime build produced from this release.
    public static let runtimeVersion = "0.1.1-rc.2-ver1"
    /// Node.js version bundled with the Runtime.
    public static let nodeVersion = "24.19.0"
    /// Harness version the Runtime installs.
    public static let harnessVersion = RuntimeLocator.harnessVersion
    /// pnpm version installed for profile and plugin commands.
    public static let pnpmVersion = "11.22.0"
    /// The single registry host accepted for dependency resolution.
    public static let registryHost = "registry.npmjs.org"
    /// Registry base URL used while installing the Runtime's dependencies.
    public static let npmRegistryURL = URL(string: "https://registry.npmjs.org")!
    /// npm integrity string required for the Harness package.
    public static let harnessPackageIntegrity = "sha512-UP1UIh6q3Gme/yXRn/QL2P8IsVlv8Shpg22TRJIZPsCRWLm4CBiA1MUvXmJAfsOEETBMLAl+xWPtFw6ICsN3wg=="
    /// npm integrity string required for the pnpm package.
    public static let pnpmPackageIntegrity = "sha512-H/hwxMYTPf2I+yr8Rt0T1H8JyXlLQ4xv20fKmMrzvBY4HuC+k6CRuOOCTPAfiJ9G19niCRD7C+GrD7W6qA3WIQ=="
    /// Data format this release creates and expects.
    public static let dataFormat = RuntimeDataFormatDescriptor(id: "sqlite-v2")

    /// Download URL of the bundled Node.js archive for an architecture.
    ///
    /// - Parameter architecture: Architecture identifier, for example `darwin-arm64`.
    /// - Returns: The download URL, or `nil` for an unsupported architecture.
    public static func nodeArchiveURL(architecture: String) -> URL? {
        nodeArchiveURL(nodeVersion: nodeVersion, architecture: architecture)
    }

    /// Download URL of a Node.js archive for an explicit version and architecture.
    ///
    /// - Parameters:
    ///   - nodeVersion: Node.js version to download.
    ///   - architecture: Architecture identifier.
    /// - Returns: The download URL, or `nil` for an unsupported architecture.
    public static func nodeArchiveURL(nodeVersion: String, architecture: String) -> URL? {
        guard let suffix = nodeArchiveSuffix(architecture: architecture) else { return nil }
        return URL(string: "https://nodejs.org/dist/v\(nodeVersion)/node-v\(nodeVersion)-darwin-\(suffix).tar.gz")
    }

    /// Expected checksum of the Node.js archive for an architecture.
    ///
    /// - Parameter architecture: Architecture identifier.
    /// - Returns: The pinned SHA-256 digest, or `nil` for an unsupported architecture.
    public static func nodeArchiveSHA256(architecture: String) -> String? {
        switch architecture {
        case "darwin-arm64":
            return "8294b7aa9b03997481c06babf1e8b270c859358f27da57a11509afe537ac381d"
        case "darwin-x64":
            return "d1b5e999db158c62fe8f7267a4476b035d8bd93b1a605bac24a3f0dd166e3316"
        default:
            return nil
        }
    }

    /// The `package.json` written into a new Runtime installation.
    public static var packageJSONData: Data {
        packageJSONData(harnessVersion: harnessVersion, pnpmVersion: pnpmVersion)
    }

    /// The `package.json` for explicit Harness and pnpm versions.
    ///
    /// - Parameters:
    ///   - harnessVersion: Harness version to depend on.
    ///   - pnpmVersion: pnpm version to depend on; defaults to ``pnpmVersion``.
    /// - Returns: UTF-8 encoded manifest data.
    public static func packageJSONData(
        harnessVersion: String,
        pnpmVersion: String = RuntimeRelease.pnpmVersion
    ) -> Data {
        Data(#"""
        {
          "name": "deepseek-harness-macos-runtime",
          "version": "0.0.1",
          "private": true,
          "dependencies": {
            "@deepseek-ai/dsh": "\#(harnessVersion)",
            "pnpm": "\#(pnpmVersion)"
          }
        }
        """#.utf8)
    }

    /// Builds the release descriptor used by the verifier and installer.
    ///
    /// - Parameter architecture: Architecture identifier.
    /// - Returns: A descriptor carrying every pinned input, or `nil` for an
    ///   unsupported architecture.
    public static func descriptor(architecture: String) -> RuntimeReleaseDescriptor? {
        guard let nodeArchiveSHA256 = nodeArchiveSHA256(architecture: architecture) else {
            return nil
        }
        return RuntimeReleaseDescriptor(
            architecture: architecture,
            nodeVersion: nodeVersion,
            harnessVersion: harnessVersion,
            pnpmVersion: pnpmVersion,
            nodeArchiveSHA256: nodeArchiveSHA256,
            harnessPackageIntegrity: harnessPackageIntegrity,
            pnpmPackageIntegrity: pnpmPackageIntegrity,
            runtimeVersion: runtimeVersion,
            dataFormat: dataFormat
        )
    }

    private static func nodeArchiveSuffix(architecture: String) -> String? {
        switch architecture {
        case "darwin-arm64": return "arm64"
        case "darwin-x64": return "x64"
        default: return nil
        }
    }
}
