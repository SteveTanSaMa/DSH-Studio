//
//  RuntimeProvisioningTypes.swift
//  DSH Studio
//

import Foundation

/// Result returned by a successful Runtime provisioning operation.
public struct RuntimeProvisioningResult: Equatable, Sendable {
    /// Installation root that was provisioned.
    public let root: URL
    /// Architecture the installation was validated for.
    public let architecture: String
    /// Manifest written for the completed installation.
    public let manifest: RuntimeInstallationManifest

    /// Creates a provisioning result.
    ///
    /// - Parameters:
    ///   - root: Installation root that was provisioned.
    ///   - architecture: Architecture the installation targets.
    ///   - manifest: Manifest written for the installation.
    public init(root: URL, architecture: String, manifest: RuntimeInstallationManifest) {
        self.root = root
        self.architecture = architecture
        self.manifest = manifest
    }
}

/// Failures raised while downloading, installing, or validating Runtime files.
public enum RuntimeProvisioningError: Error, Equatable, LocalizedError, Sendable {
    /// The host architecture has no pinned Runtime artifact.
    case unsupportedArchitecture(String)
    /// The packaged dependency lockfile is missing.
    case packageLockUnavailable
    /// The dependency lockfile failed validation; carries the detail.
    case invalidPackageLock(String)
    /// An artifact download failed; carries the transport detail.
    case downloadFailed(String)
    /// A downloaded artifact did not match its pinned checksum.
    case checksumMismatch(expected: String, actual: String)
    /// A setup command exited unsuccessfully; carries status and output detail.
    case commandFailed(status: Int32, detail: String)
    /// Installing the extracted Runtime failed; carries the detail.
    case installationFailed(String)
    /// The installed Runtime did not validate; carries the failing check.
    case runtimeValidationFailed(String)
    /// The app has no verified artifact for the required release.
    case runtimeArtifactUnavailable
    /// The release declares no data contract, so takeover was blocked.
    case dataCompatibilityUnknown
    /// The stored data uses a format the release cannot read.
    case dataIncompatible
    /// The stored data needs migration before the release can run.
    case dataMigrationRequired
    /// No previous Runtime build is available to restore.
    case rollbackUnavailable
    /// Restoring the previous build failed; carries the detail.
    case rollbackFailed(String)

    /// A localized, user-facing description of the failure.
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
