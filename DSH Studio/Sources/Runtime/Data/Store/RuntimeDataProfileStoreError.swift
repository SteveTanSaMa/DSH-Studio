//
//  RuntimeDataProfileStoreError.swift
//  DSH Studio
//

import Foundation

/// Failures raised while persisting or activating a data profile.
///
/// The format cases are the fail-closed half of activation: when compatibility
/// cannot be proven, the store refuses to hand a Runtime an existing data home.
public enum RuntimeDataProfileStoreError: Error, Equatable, LocalizedError, Sendable {
    /// The profile descriptor failed validation.
    case invalidProfile
    /// The stored `active-state.json` is unreadable or invalid.
    case invalidActiveState
    /// No profile exists for the identifier; carries the identifier.
    case profileNotFound(String)
    /// Compatibility cannot be determined from the available declarations.
    case dataFormatUnknown
    /// The stored and declared data formats cannot be reconciled.
    case dataFormatMismatch(profile: String, runtime: String)
    /// The stored data needs migration before this Runtime may use it.
    case dataMigrationRequired(profile: String, runtime: String)
    /// A write failed; carries the underlying detail.
    case persistenceFailed(String)

    /// A localized, user-facing description of the failure.
    public var errorDescription: String? {
        switch self {
        case .invalidProfile:
            return "Runtime 数据环境描述无效"
        case .invalidActiveState:
            return "Runtime active-state.json 无效"
        case .profileNotFound(let id):
            return "找不到 Runtime 数据环境：\(id)"
        case .dataFormatUnknown:
            return "无法确认数据环境与 Runtime 的格式关系"
        case .dataFormatMismatch(let profile, let runtime):
            return "数据环境格式 \(profile) 与 Runtime 格式 \(runtime) 不兼容"
        case .dataMigrationRequired(let profile, let runtime):
            return "数据环境格式 \(profile) 需要迁移到 Runtime 格式 \(runtime)"
        case .persistenceFailed(let detail):
            return "Runtime 数据环境状态保存失败：\(detail)"
        }
    }
}
