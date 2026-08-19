//
//  RuntimeProvisioningSupport.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import Foundation

/// Versioned metadata written only after a complete Runtime installation.
public struct RuntimeInstallationManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let architecture: String
    public let nodeVersion: String
    public let harnessVersion: String
    public let nodeSHA256: String
    public let harnessPackageIntegrity: String

    public init(
        schemaVersion: Int = currentSchemaVersion,
        architecture: String,
        nodeVersion: String,
        harnessVersion: String,
        nodeSHA256: String,
        harnessPackageIntegrity: String
    ) {
        self.schemaVersion = schemaVersion
        self.architecture = architecture
        self.nodeVersion = nodeVersion
        self.harnessVersion = harnessVersion
        self.nodeSHA256 = nodeSHA256
        self.harnessPackageIntegrity = harnessPackageIntegrity
    }
}

/// Result returned by a successful Runtime provisioning operation.
public struct RuntimeProvisioningResult: Equatable, Sendable {
    public let root: URL
    public let architecture: String
    public let manifest: RuntimeInstallationManifest

    public init(root: URL, architecture: String, manifest: RuntimeInstallationManifest) {
        self.root = root
        self.architecture = architecture
        self.manifest = manifest
    }
}

/// Failures raised while downloading, installing, or validating Runtime files.
public enum RuntimeProvisioningError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedArchitecture(String)
    case packageLockUnavailable
    case invalidPackageLock(String)
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case commandFailed(status: Int32, detail: String)
    case installationFailed(String)
    case runtimeValidationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture(let architecture):
            return "不支持的 macOS Runtime 架构：\(architecture)"
        case .packageLockUnavailable:
            return "找不到锁定的 Harness 依赖清单"
        case .invalidPackageLock(let detail):
            return "Harness 依赖清单校验失败：\(detail)"
        case .downloadFailed(let detail):
            return "Runtime 下载失败：\(detail)"
        case .checksumMismatch:
            return "Node Runtime 校验和不匹配"
        case .commandFailed(let status, let detail):
            return detail.isEmpty ? "Runtime 配置命令失败（状态码 \(status)）" : "Runtime 配置命令失败：\(detail)"
        case .installationFailed(let detail):
            return "Runtime 安装失败：\(detail)"
        case .runtimeValidationFailed(let detail):
            return "Runtime 安装结果无效：\(detail)"
        }
    }
}

/// Fixed release inputs used by the verified online Runtime installer.
///
/// These values intentionally avoid mutable "latest" URLs and remote install
/// scripts. Every network request can therefore be checked against a known
/// host, version, integrity value, and archive checksum.
public enum RuntimeRelease {
    public static let nodeVersion = "24.19.0"
    public static let harnessVersion = RuntimeLocator.harnessVersion
    public static let registryHost = "registry.npmjs.org"
    public static let npmRegistryURL = URL(string: "https://registry.npmjs.org")!
    public static let harnessPackageIntegrity = "sha512-brpZfED7ieRa2PQ5tUxMhHrM1pb2CmKFVM/f6yMULBDMicahk+Z2OsHgTwTDnoiZm23Ftu9rQz0NN4pflaoJcg=="

    public static func nodeArchiveURL(architecture: String) -> URL? {
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
        Data(#"""
        {
          "name": "deepseek-harness-macos-runtime",
          "version": "0.0.1",
          "private": true,
          "dependencies": {
            "@deepseek-ai/dsh": "0.1.0-rc.6"
          }
        }
        """#.utf8)
    }

    private static func nodeArchiveSuffix(architecture: String) -> String? {
        switch architecture {
        case "darwin-arm64": return "arm64"
        case "darwin-x64": return "x64"
        default: return nil
        }
    }
}

/// Validates the npm lockfile before npm is allowed to install dependencies.
public enum RuntimePackageLockValidator {
    public static func validate(
        data: Data,
        expectedHarnessVersion: String = RuntimeRelease.harnessVersion,
        expectedHarnessIntegrity: String = RuntimeRelease.harnessPackageIntegrity,
        expectedRegistryHost: String = RuntimeRelease.registryHost
    ) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lockfileVersion = root["lockfileVersion"] as? Int,
              lockfileVersion == 3,
              let packages = root["packages"] as? [String: Any],
              let packageRoot = packages[""] as? [String: Any],
              let dependencies = packageRoot["dependencies"] as? [String: Any],
              dependencies[RuntimeLocator.dshPackageName] as? String == expectedHarnessVersion else {
            throw RuntimeProvisioningError.invalidPackageLock("根依赖或 lockfileVersion 无效")
        }

        guard let harnessPackage = packages["node_modules/\(RuntimeLocator.dshPackageName)"] as? [String: Any],
              harnessPackage["version"] as? String == expectedHarnessVersion,
              harnessPackage["integrity"] as? String == expectedHarnessIntegrity else {
            throw RuntimeProvisioningError.invalidPackageLock("Harness 包版本或 integrity 无效")
        }

        for (path, rawPackage) in packages where !path.isEmpty {
            guard let package = rawPackage as? [String: Any],
                  let integrity = package["integrity"] as? String,
                  !integrity.isEmpty else {
                throw RuntimeProvisioningError.invalidPackageLock("缺少 \(path) 的 integrity")
            }
            guard let resolved = package["resolved"] as? String,
                  let components = URLComponents(string: resolved),
                  components.scheme == "https",
                  components.host == expectedRegistryHost,
                  components.user == nil,
                  components.password == nil,
                  components.port == nil else {
                throw RuntimeProvisioningError.invalidPackageLock("\(path) 不是官方 npm registry tarball")
            }
        }
    }
}

/// Abstraction around downloading the pinned Node archive.
public protocol RuntimeAssetDownloading: Sendable {
    func download(from url: URL, to destination: URL) async throws
}

/// Abstraction around the local `tar` and `npm` commands used during setup.
public protocol RuntimeProvisioning: Sendable {
    var root: URL { get }
    var architecture: String { get }
    func provision() async throws -> RuntimeProvisioningResult
}
