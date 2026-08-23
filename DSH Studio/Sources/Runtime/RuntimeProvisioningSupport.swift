//
//  RuntimeProvisioningSupport.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import Foundation

/// An immutable Runtime archive published by the Runtime Builder.
public struct RuntimeArtifactDescriptor: Codable, Equatable, Sendable {
    public let runtimeVersion: String
    public let architecture: String
    public let url: URL
    public let sha256: String

    public init(
        runtimeVersion: String,
        architecture: String,
        url: URL,
        sha256: String
    ) {
        self.runtimeVersion = runtimeVersion
        self.architecture = architecture
        self.url = url
        self.sha256 = sha256
    }
}

/// Immutable, verified inputs for one Runtime release.
///
/// A release is deliberately described by values compiled into the app. This
/// keeps update checks deterministic and prevents a mutable remote "latest"
/// document from selecting an unverified dependency graph.
public struct RuntimeReleaseDescriptor: Codable, Equatable, Sendable {
    public let runtimeVersion: String
    public let architecture: String
    public let nodeVersion: String
    public let harnessVersion: String
    public let pnpmVersion: String
    public let nodeArchiveSHA256: String
    public let harnessPackageIntegrity: String
    public let pnpmPackageIntegrity: String
    public let artifact: RuntimeArtifactDescriptor?
    public let dataFormat: RuntimeDataFormatDescriptor?

    public init(
        architecture: String,
        nodeVersion: String,
        harnessVersion: String,
        pnpmVersion: String,
        nodeArchiveSHA256: String,
        harnessPackageIntegrity: String,
        pnpmPackageIntegrity: String,
        runtimeVersion: String = RuntimeRelease.runtimeVersion,
        artifact: RuntimeArtifactDescriptor? = nil,
        dataFormat: RuntimeDataFormatDescriptor? = nil
    ) {
        self.runtimeVersion = runtimeVersion
        self.architecture = architecture
        self.nodeVersion = nodeVersion
        self.harnessVersion = harnessVersion
        self.pnpmVersion = pnpmVersion
        self.nodeArchiveSHA256 = nodeArchiveSHA256
        self.harnessPackageIntegrity = harnessPackageIntegrity
        self.pnpmPackageIntegrity = pnpmPackageIntegrity
        self.artifact = artifact
        self.dataFormat = dataFormat
    }

    public var versionLabel: String {
        "Runtime \(runtimeVersion) / Harness \(harnessVersion) / Node \(nodeVersion)"
    }
}

/// Versioned metadata written only after a complete Runtime installation.
public struct RuntimeInstallationManifest: Codable, Equatable, Sendable {
    // Version 2 records the Runtime-owned pnpm dependency required by the
    // Harness plugin/profile commands. Older manifests are intentionally not
    // adopted because they may depend on an unrelated system pnpm.
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public let runtimeVersion: String
    public let architecture: String
    public let nodeVersion: String
    public let harnessVersion: String
    public let pnpmVersion: String
    public let nodeSHA256: String
    public let harnessPackageIntegrity: String
    public let pnpmPackageIntegrity: String
    public let dataFormat: RuntimeDataFormatDescriptor?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        runtimeVersion: String = RuntimeRelease.runtimeVersion,
        architecture: String,
        nodeVersion: String,
        harnessVersion: String,
        pnpmVersion: String = RuntimeRelease.pnpmVersion,
        nodeSHA256: String,
        harnessPackageIntegrity: String,
        pnpmPackageIntegrity: String = RuntimeRelease.pnpmPackageIntegrity,
        dataFormat: RuntimeDataFormatDescriptor? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.runtimeVersion = runtimeVersion
        self.architecture = architecture
        self.nodeVersion = nodeVersion
        self.harnessVersion = harnessVersion
        self.pnpmVersion = pnpmVersion
        self.nodeSHA256 = nodeSHA256
        self.harnessPackageIntegrity = harnessPackageIntegrity
        self.pnpmPackageIntegrity = pnpmPackageIntegrity
        self.dataFormat = dataFormat
    }

    public var versionLabel: String {
        "Harness \(harnessVersion) / Node \(nodeVersion)"
    }

    public func matches(_ release: RuntimeReleaseDescriptor) -> Bool {
        schemaVersion == Self.currentSchemaVersion
            && runtimeVersion == release.runtimeVersion
            && architecture == release.architecture
            && nodeVersion == release.nodeVersion
            && harnessVersion == release.harnessVersion
            && pnpmVersion == release.pnpmVersion
            && nodeSHA256 == release.nodeArchiveSHA256
            && harnessPackageIntegrity == release.harnessPackageIntegrity
            && pnpmPackageIntegrity == release.pnpmPackageIntegrity
            && dataFormat == release.dataFormat
    }
}

public extension RuntimeReleaseDescriptor {
    /// Reconstructs the currently installed Runtime contract when no catalog
    /// is available. The artifact remains nil because an installed manifest
    /// proves what can be launched, not what may be downloaded next.
    init(manifest: RuntimeInstallationManifest) {
        self.init(
            architecture: manifest.architecture,
            nodeVersion: manifest.nodeVersion,
            harnessVersion: manifest.harnessVersion,
            pnpmVersion: manifest.pnpmVersion,
            nodeArchiveSHA256: manifest.nodeSHA256,
            harnessPackageIntegrity: manifest.harnessPackageIntegrity,
            pnpmPackageIntegrity: manifest.pnpmPackageIntegrity,
            runtimeVersion: manifest.runtimeVersion,
            artifact: nil,
            dataFormat: manifest.dataFormat
        )
    }
}

public enum RuntimeVersionStatusKind: String, Codable, Equatable, Sendable {
    case missing
    case invalid
    case current
    case newerInstalled
    case updateAvailable
    case updatePrepared
    case updateBlocked
}

/// The result of comparing the installed Runtime with the app's pinned release.
public struct RuntimeVersionStatus: Codable, Equatable, Sendable {
    public let kind: RuntimeVersionStatusKind
    public let installed: RuntimeInstallationManifest?
    public let available: RuntimeReleaseDescriptor
    public let prepared: RuntimeInstallationManifest?
    public let activeProfileID: String?
    public let activeDataFormatID: String?
    public let rollbackAvailable: Bool

    public init(
        kind: RuntimeVersionStatusKind,
        installed: RuntimeInstallationManifest?,
        available: RuntimeReleaseDescriptor,
        prepared: RuntimeInstallationManifest? = nil,
        activeProfileID: String? = nil,
        activeDataFormatID: String? = nil,
        rollbackAvailable: Bool
    ) {
        self.kind = kind
        self.installed = installed
        self.available = available
        self.prepared = prepared
        self.activeProfileID = activeProfileID
        self.activeDataFormatID = activeDataFormatID
        self.rollbackAvailable = rollbackAvailable
    }

    public var updateAvailable: Bool {
        kind == .updateAvailable || kind == .updatePrepared
    }

    public var updatePrepared: Bool {
        kind == .updatePrepared
    }

    /// Compares the candidate release with the data contract recorded by the
    /// selected data profile. The installed Runtime's own declaration is not
    /// used as a proxy for an unknown profile, because it does not prove what
    /// is actually stored in that profile.
    public var dataCompatibility: RuntimeDataCompatibility {
        guard let dataFormat = available.dataFormat,
              activeProfileID != nil else {
            return .unknown
        }
        // The installed Runtime describes what it expects, not what is
        // actually stored in an unregistered data home. Reusing that
        // declaration here would turn an unknown profile into a false
        // compatibility success.
        return dataFormat.compatibility(with: activeDataFormatID)
    }

    /// A declared data contract is required before an update may reuse the
    /// currently active data home.
    public var canReuseInstalledData: Bool {
        dataCompatibility == .compatible
    }

    public var displayName: String {
        switch kind {
        case .missing:
            return "尚未安装 Runtime"
        case .invalid:
            return "Runtime 需要修复或更新"
        case .current:
            return "Runtime 已是最新版本"
        case .newerInstalled:
            return "已安装更高版本 Runtime"
        case .updateAvailable:
            switch dataCompatibility {
            case .compatible:
                return "发现 Runtime 更新"
            case .incompatible:
                return "发现 Runtime 更新，但数据格式不兼容"
            case .requiresMigration:
                return "发现 Runtime 更新，需要数据迁移"
            case .unknown:
                return "发现 Runtime 更新，需要确认数据兼容性"
            }
        case .updatePrepared:
            switch dataCompatibility {
            case .compatible:
                return "Runtime 更新已下载并验证"
            case .incompatible:
                return "Runtime 更新已准备，但数据格式不兼容"
            case .requiresMigration:
                return "Runtime 更新已准备，但需要数据迁移"
            case .unknown:
                return "Runtime 更新已准备，需要确认数据兼容性"
            }
        case .updateBlocked:
            return "Runtime 更新版本内容冲突，需要修复"
        }
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
    case runtimeArtifactUnavailable
    case dataCompatibilityUnknown
    case dataIncompatible
    case dataMigrationRequired
    case rollbackUnavailable
    case rollbackFailed(String)

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
        case .runtimeArtifactUnavailable:
            return "当前 App 未包含可验证的 Runtime artifact"
        case .dataCompatibilityUnknown:
            return "无法确认新 Runtime 与当前数据是否兼容，已阻止自动接管"
        case .dataIncompatible:
            return "新 Runtime 与当前数据格式不兼容，已阻止自动接管"
        case .dataMigrationRequired:
            return "新 Runtime 需要数据迁移，已阻止自动接管"
        case .rollbackUnavailable:
            return "没有可用的 Runtime 回滚版本"
        case .rollbackFailed(let detail):
            return "Runtime 回滚失败：\(detail)"
        }
    }
}

/// Fixed release inputs used by the verified online Runtime installer.
///
/// These values intentionally avoid mutable "latest" URLs and remote install
/// scripts. Every network request can therefore be checked against a known
/// host, version, integrity value, and archive checksum.
public enum RuntimeRelease {
    public static let runtimeVersion = "2026.08.20.1"
    public static let nodeVersion = "24.19.0"
    public static let harnessVersion = RuntimeLocator.harnessVersion
    public static let pnpmVersion = "11.7.0"
    public static let registryHost = "registry.npmjs.org"
    public static let npmRegistryURL = URL(string: "https://registry.npmjs.org")!
    public static let harnessPackageIntegrity = "sha512-brpZfED7ieRa2PQ5tUxMhHrM1pb2CmKFVM/f6yMULBDMicahk+Z2OsHgTwTDnoiZm23Ftu9rQz0NN4pflaoJcg=="
    public static let pnpmPackageIntegrity = "sha512-GcyFLBIMcSV2DyRD7mvgyltA+fUFmN4aCaHxd1A+AQ5Xwjx3ZG4B52HeWb+HT7IqM5jDOrlpH8E+uUa28PTWIA=="

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
            runtimeVersion: runtimeVersion
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

/// Validates the npm lockfile before npm is allowed to install dependencies.
public enum RuntimePackageLockValidator {
    public static func validate(
        data: Data,
        expectedHarnessVersion: String = RuntimeRelease.harnessVersion,
        expectedHarnessIntegrity: String = RuntimeRelease.harnessPackageIntegrity,
        expectedPnpmVersion: String = RuntimeRelease.pnpmVersion,
        expectedPnpmIntegrity: String = RuntimeRelease.pnpmPackageIntegrity,
        expectedRegistryHost: String = RuntimeRelease.registryHost
    ) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lockfileVersion = root["lockfileVersion"] as? Int,
              lockfileVersion == 3,
              let packages = root["packages"] as? [String: Any],
              let packageRoot = packages[""] as? [String: Any],
              let dependencies = packageRoot["dependencies"] as? [String: Any],
              dependencies[RuntimeLocator.dshPackageName] as? String == expectedHarnessVersion,
              dependencies["pnpm"] as? String == expectedPnpmVersion else {
            throw RuntimeProvisioningError.invalidPackageLock("根依赖或 lockfileVersion 无效")
        }

        guard let harnessPackage = packages["node_modules/\(RuntimeLocator.dshPackageName)"] as? [String: Any],
              harnessPackage["version"] as? String == expectedHarnessVersion,
              harnessPackage["integrity"] as? String == expectedHarnessIntegrity else {
            throw RuntimeProvisioningError.invalidPackageLock("Harness 包版本或 integrity 无效")
        }

        guard let pnpmPackage = packages["node_modules/pnpm"] as? [String: Any],
              pnpmPackage["version"] as? String == expectedPnpmVersion,
              pnpmPackage["integrity"] as? String == expectedPnpmIntegrity else {
            throw RuntimeProvisioningError.invalidPackageLock("pnpm 包版本或 integrity 无效")
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

/// Operations that can inspect, replace, and restore an installed Runtime.
public protocol RuntimeUpdating: RuntimeProvisioning {
    func versionStatus() -> RuntimeVersionStatus
    func update() async throws -> RuntimeProvisioningResult
    func rollback() throws -> RuntimeProvisioningResult
}

/// Two-phase Runtime updates. Preparation may happen while the current
/// Harness keeps running; activation is the explicit point where the active
/// Runtime is replaced.
public protocol RuntimeCandidateUpdating: RuntimeUpdating {
    func prepareUpdate() async throws -> RuntimeProvisioningResult
    func activatePreparedUpdate() throws -> RuntimeProvisioningResult
}

/// Replaces the release selected by an already-running app after a verified
/// remote catalog has been discovered. This does not install or activate a
/// Runtime; it only changes the next update target.
public protocol RuntimeReleaseUpdating: Sendable {
    var release: RuntimeReleaseDescriptor { get }
    func setRelease(_ release: RuntimeReleaseDescriptor) throws
}

/// Lets the Runtime update layer evaluate a release against the data profile
/// that the app is about to use. The Runtime and data profile remain separate
/// objects even though the production provisioner needs the selected profile ID
/// for status reporting.
public protocol RuntimeDataProfileSelecting: Sendable {
    var dataProfileID: String? { get }
    func setDataProfileID(_ id: String?)
}

public enum RuntimeUpdateError: Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case noUpdateAvailable
    case runtimeVersionConflict
    case dataCompatibilityUnknown
    case dataIncompatible
    case dataMigrationRequired
    case rollbackUnavailable
    case updateFailed(String)
    case rollbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "当前 Runtime 不支持在线更新"
        case .noUpdateAvailable:
            return "当前 Runtime 已是最新版本"
        case .runtimeVersionConflict:
            return "Runtime 更新版本内容冲突，已阻止更新"
        case .dataCompatibilityUnknown:
            return "无法确认新 Runtime 与当前数据是否兼容，已阻止自动接管"
        case .dataIncompatible:
            return "新 Runtime 与当前数据格式不兼容，已阻止自动接管"
        case .dataMigrationRequired:
            return "新 Runtime 需要数据迁移，已阻止自动接管"
        case .rollbackUnavailable:
            return "没有可用的 Runtime 回滚版本"
        case .updateFailed(let detail):
            return "Runtime 更新失败：\(detail)"
        case .rollbackFailed(let detail):
            return "Runtime 回滚失败：\(detail)"
        }
    }
}
