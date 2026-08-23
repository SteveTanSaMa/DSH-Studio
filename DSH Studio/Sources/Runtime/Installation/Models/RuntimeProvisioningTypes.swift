//
//  RuntimeProvisioningTypes.swift
//  DSH Studio
//

import Foundation

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
