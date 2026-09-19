//
//  RuntimeProvisioningModels.swift
//  DSH Studio
//

import Foundation

/// A downloadable Runtime archive together with the checksum it must match.
///
/// This is the only place a Runtime update may be fetched from, and the
/// provisioner verifies ``sha256`` before the archive is unpacked.
public struct RuntimeArtifactDescriptor: Codable, Equatable, Sendable {
    /// The Runtime build contained in the archive.
    public let runtimeVersion: String
    /// The CPU architecture the archive targets, for example `arm64`.
    public let architecture: String
    /// Location the archive is downloaded from.
    public let url: URL
    /// Expected archive checksum, verified before extraction.
    public let sha256: String

    /// Creates a descriptor for one downloadable Runtime archive.
    ///
    /// - Parameters:
    ///   - runtimeVersion: Runtime build contained in the archive.
    ///   - architecture: Architecture the archive targets.
    ///   - url: Download location.
    ///   - sha256: Checksum the downloaded file must match.
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
    /// The Runtime build version this app pins.
    public let runtimeVersion: String
    /// The architecture this release targets.
    public let architecture: String
    /// The bundled Node.js version.
    public let nodeVersion: String
    /// The Harness version this release ships.
    public let harnessVersion: String
    /// The pnpm version used for profile and plugin commands.
    public let pnpmVersion: String
    /// Checksum of the Node.js archive.
    public let nodeArchiveSHA256: String
    /// npm integrity string for the Harness package.
    public let harnessPackageIntegrity: String
    /// npm integrity string for the pnpm package.
    public let pnpmPackageIntegrity: String
    /// The downloadable Runtime archive, or `nil` when only the installed contract is known.
    public let artifact: RuntimeArtifactDescriptor?
    /// The data contract this release expects, when the release declares one.
    public let dataFormat: RuntimeDataFormatDescriptor?

    /// Creates a release descriptor.
    ///
    /// Runtime version and dependency defaults come from ``RuntimeRelease``, which
    /// keeps a catalog entry consistent with the app's compiled-in pin.
    ///
    /// - Parameters:
    ///   - architecture: Architecture this release targets.
    ///   - nodeVersion: Bundled Node.js version.
    ///   - harnessVersion: Harness version this release ships.
    ///   - pnpmVersion: pnpm version used for profile commands.
    ///   - nodeArchiveSHA256: Checksum of the Node.js archive.
    ///   - harnessPackageIntegrity: npm integrity string for the Harness package.
    ///   - pnpmPackageIntegrity: npm integrity string for the pnpm package.
    ///   - runtimeVersion: Runtime build version; defaults to the compiled-in pin.
    ///   - artifact: Downloadable archive, when one is offered.
    ///   - dataFormat: Data contract the release expects, when declared.
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

    /// A single-line label listing the Runtime, Harness, and Node versions.
    public var versionLabel: String {
        "Runtime \(runtimeVersion) / Harness \(harnessVersion) / Node \(nodeVersion)"
    }
}

/// Versioned metadata written only after a complete Runtime installation.
public struct RuntimeInstallationManifest: Codable, Equatable, Sendable {
    /// The manifest schema this app writes; manifests of any other version are rejected.
    ///
    /// Version 3 added the Runtime build version plus the Runtime-owned pnpm dependency
    /// (`runtimeVersion`, `pnpmVersion`, `pnpmPackageIntegrity`), so an older manifest
    /// cannot prove which dependencies it holds and is intentionally not adopted. There
    /// was no committed version 2: the number moved from 1 straight to 3.
    ///
    /// - Note: `dataFormat` was added after version 3 without a further bump, so a
    ///   version 3 manifest may or may not carry it. A manifest written before that
    ///   change decodes it as `nil` and therefore fails ``matches(_:)`` against a
    ///   release that declares a format; the installation is then treated as not
    ///   matching and is reinstalled. That is wasteful but fail-safe.
    public static let currentSchemaVersion = 3

    /// Schema version recorded when the Runtime was installed.
    public let schemaVersion: Int
    /// Runtime build version that was installed.
    public let runtimeVersion: String
    /// Architecture the installed Runtime was validated for.
    public let architecture: String
    /// Bundled Node.js version of the installation.
    public let nodeVersion: String
    /// Harness version of the installation.
    public let harnessVersion: String
    /// pnpm version recorded by the installation.
    public let pnpmVersion: String
    /// Checksum of the Node.js archive that was installed.
    public let nodeSHA256: String
    /// Integrity string of the installed Harness package.
    public let harnessPackageIntegrity: String
    /// Integrity string of the installed pnpm package.
    public let pnpmPackageIntegrity: String
    /// Data contract the installation was created for, when it declared one.
    public let dataFormat: RuntimeDataFormatDescriptor?

    /// Creates a manifest for a completed installation.
    ///
    /// Version and dependency defaults mirror ``RuntimeRelease`` so an installation
    /// record always matches the app's compiled-in pin unless a caller overrides it.
    ///
    /// - Parameters:
    ///   - schemaVersion: Manifest schema; defaults to ``currentSchemaVersion``.
    ///   - runtimeVersion: Installed Runtime build; defaults to the compiled-in pin.
    ///   - architecture: Architecture the Runtime was validated for.
    ///   - nodeVersion: Bundled Node.js version.
    ///   - harnessVersion: Installed Harness version.
    ///   - pnpmVersion: Installed pnpm version.
    ///   - nodeSHA256: Checksum of the installed Node.js archive.
    ///   - harnessPackageIntegrity: Integrity string of the Harness package.
    ///   - pnpmPackageIntegrity: Integrity string of the pnpm package.
    ///   - dataFormat: Data contract of the installation, when declared.
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

    /// A compact Harness and Node version label for the installed Runtime.
    public var versionLabel: String {
        "Harness \(harnessVersion) / Node \(nodeVersion)"
    }

    /// Whether the installation matches a release descriptor field by field.
    ///
    /// Used before an update is allowed to reuse the existing installation: a
    /// mismatch in any archived dependency or data contract invalidates the reuse.
    ///
    /// - Parameter release: Release the installation is compared against.
    /// - Returns: `true` when schema, versions, checksums, and data contract agree.
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

/// Reconstruction of a release descriptor from an installed manifest.
public extension RuntimeReleaseDescriptor {
    /// Reconstructs the installed Runtime contract when no catalog is available.
    ///
    /// The artifact stays `nil`: an installed manifest proves what can be launched,
    /// not what may be downloaded next.
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

/// How the installed Runtime compares with the release this app pins.
public enum RuntimeVersionStatusKind: String, Codable, Equatable, Sendable {
    /// No usable Runtime installation was found.
    case missing
    /// An installation exists but fails validation.
    case invalid
    /// The installation matches the pinned release.
    case current
    /// A newer Runtime is installed than this app pins.
    case newerInstalled
    /// The pinned release is newer than the installation.
    case updateAvailable
    /// An update is downloaded and verified but not yet activated.
    case updatePrepared
    /// The update cannot be applied until the content conflict is repaired.
    case updateBlocked
}

/// The result of comparing the installed Runtime with the app's pinned release.
public struct RuntimeVersionStatus: Codable, Equatable, Sendable {
    /// The comparison verdict; decides which maintenance actions Settings offers.
    public let kind: RuntimeVersionStatusKind
    /// Manifest of the installation on disk, when one is valid.
    public let installed: RuntimeInstallationManifest?
    /// The release this app would install.
    public let available: RuntimeReleaseDescriptor
    /// A downloaded, verified update waiting to be activated.
    public let prepared: RuntimeInstallationManifest?
    /// Identifier of the data profile in use, when it is registered.
    public let activeProfileID: String?
    /// Data format stored by the active profile, when it is known.
    public let activeDataFormatID: String?
    /// Whether a previously installed Runtime build can still be restored.
    public let rollbackAvailable: Bool

    /// Creates a comparison result.
    ///
    /// - Parameters:
    ///   - kind: Comparison verdict.
    ///   - installed: Manifest of the valid installation on disk, if any.
    ///   - available: Release this app would install.
    ///   - prepared: Downloaded and verified update, if one is waiting.
    ///   - activeProfileID: Data profile in use, when registered.
    ///   - activeDataFormatID: Data format stored by that profile, when known.
    ///   - rollbackAvailable: Whether the previous build can be restored.
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

    /// Whether an update is offered or already prepared for activation.
    public var updateAvailable: Bool {
        kind == .updateAvailable || kind == .updatePrepared
    }

    /// Whether a verified update is waiting to be activated.
    public var updatePrepared: Bool {
        kind == .updatePrepared
    }

    /// How the candidate release's data contract compares with the active profile.
    ///
    /// The installed Runtime's own declaration is not used as a proxy for an unknown
    /// profile, because it does not prove what is actually stored in that profile.
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

    /// Whether an update may reuse the currently active data home.
    ///
    /// A declared, matching data contract is required before reuse is allowed.
    /// A declared data contract is required before an update may reuse the
    /// currently active data home.
    public var canReuseInstalledData: Bool {
        dataCompatibility == .compatible
    }

    /// A localized summary of the comparison, including data compatibility.
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
