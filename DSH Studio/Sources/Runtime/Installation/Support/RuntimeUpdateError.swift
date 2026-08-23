//
//  RuntimeUpdateError.swift
//  DSH Studio
//

import Foundation

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
