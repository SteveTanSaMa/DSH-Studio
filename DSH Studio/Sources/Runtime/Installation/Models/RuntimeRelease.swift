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
    public static let runtimeVersion = "0.1.1-rc.2-ver1"
    public static let nodeVersion = "24.19.0"
    public static let harnessVersion = RuntimeLocator.harnessVersion
    public static let pnpmVersion = "11.22.0"
    public static let registryHost = "registry.npmjs.org"
    public static let npmRegistryURL = URL(string: "https://registry.npmjs.org")!
    public static let harnessPackageIntegrity = "sha512-UP1UIh6q3Gme/yXRn/QL2P8IsVlv8Shpg22TRJIZPsCRWLm4CBiA1MUvXmJAfsOEETBMLAl+xWPtFw6ICsN3wg=="
    public static let pnpmPackageIntegrity = "sha512-H/hwxMYTPf2I+yr8Rt0T1H8JyXlLQ4xv20fKmMrzvBY4HuC+k6CRuOOCTPAfiJ9G19niCRD7C+GrD7W6qA3WIQ=="
    public static let dataFormat = RuntimeDataFormatDescriptor(id: "sqlite-v2")

    public static func nodeArchiveURL(architecture: String) -> URL? {
        nodeArchiveURL(nodeVersion: nodeVersion, architecture: architecture)
    }

    public static func nodeArchiveURL(nodeVersion: String, architecture: String) -> URL? {
        guard let suffix = nodeArchiveSuffix(architecture: architecture) else { return nil }
        return URL(string: "https://nodejs.org/dist/v\(nodeVersion)/node-v\(nodeVersion)-darwin-\(suffix).tar.gz")
    }

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

    public static var packageJSONData: Data {
        packageJSONData(harnessVersion: harnessVersion, pnpmVersion: pnpmVersion)
    }

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
