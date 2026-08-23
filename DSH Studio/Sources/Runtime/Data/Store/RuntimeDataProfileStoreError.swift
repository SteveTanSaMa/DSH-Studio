//
//  RuntimeDataProfileStoreError.swift
//  DSH Studio
//

import Foundation

public enum RuntimeDataProfileStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidProfile
    case invalidActiveState
    case profileNotFound(String)
    case dataFormatUnknown
    case dataFormatMismatch(profile: String, runtime: String)
    case dataMigrationRequired(profile: String, runtime: String)
    case persistenceFailed(String)

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
