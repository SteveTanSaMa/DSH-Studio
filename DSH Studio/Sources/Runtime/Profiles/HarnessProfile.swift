//
//  HarnessProfile.swift
//  DSH Studio
//

import Foundation

public struct HarnessProfile: Codable, Equatable, Sendable {
    public let name: String
    public let directory: URL
    public let bundles: [String]
    public let exists: Bool
    public let selectable: Bool
    public let problem: String?

    public init(
        name: String,
        directory: URL,
        bundles: [String],
        exists: Bool,
        selectable: Bool,
        problem: String? = nil
    ) {
        self.name = name
        self.directory = directory
        self.bundles = bundles
        self.exists = exists
        self.selectable = selectable
        self.problem = problem
    }
}

public enum HarnessProfileStatus: String, Codable, Equatable, Sendable {
    case active
    case pending
    case lastKnownGood
    case ready
    case invalid

    public var displayName: String {
        switch self {
        case .active:
            return "当前"
        case .pending:
            return "待启动"
        case .lastKnownGood:
            return "上次可用"
        case .ready:
            return "可用"
        case .invalid:
            return "不可用"
        }
    }
}

public struct HarnessProfileSelection: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let active: String
    public let pending: String?
    public let lastKnownGood: String

    public init(
        version: Int = currentVersion,
        active: String,
        pending: String? = nil,
        lastKnownGood: String
    ) {
        self.version = version
        self.active = active
        self.pending = pending
        self.lastKnownGood = lastKnownGood
    }

    public var isValid: Bool {
        version == Self.currentVersion
            && HarnessProfileStore.isSafeName(active)
            && HarnessProfileStore.isSafeName(lastKnownGood)
            && (pending == nil || HarnessProfileStore.isSafeName(pending!))
    }
}

public enum HarnessProfileStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidName
    case alreadyExists
    case notFound
    case notSelectable(String)
    case cannotDeleteActive
    case malformedManifest(String)
    case persistenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Profile 名称无效"
        case .alreadyExists:
            return "Profile 已存在"
        case .notFound:
            return "Profile 不存在"
        case .notSelectable(let detail):
            return "Profile 无法启动：\(detail)"
        case .cannotDeleteActive:
            return "当前 Profile 不能删除"
        case .malformedManifest(let detail):
            return "Profile 配置无效：\(detail)"
        case .persistenceFailed(let detail):
            return "Profile 保存失败：\(detail)"
        }
    }
}
