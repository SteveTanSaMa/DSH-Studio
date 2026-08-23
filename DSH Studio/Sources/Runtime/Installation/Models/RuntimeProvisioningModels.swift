//
//  RuntimeProvisioningModels.swift
//  DSH Studio
//

import Foundation

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
