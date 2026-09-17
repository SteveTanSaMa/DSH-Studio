//
//  HarnessProfile.swift
//  DSH Studio
//

import Foundation

/// One Harness composition profile discovered under `DSH_HOME/profiles`.
public struct HarnessProfile: Codable, Equatable, Sendable {
    /// Profile name, equal to its directory name.
    public let name: String
    /// The profile directory.
    public let directory: URL
    /// Bundle package names the profile loads, in resolution order.
    public let bundles: [String]
    /// Whether the profile directory exists on disk; the default profile may be virtual.
    public let exists: Bool
    /// Whether the profile can be launched as-is.
    public let selectable: Bool
    /// Why the profile cannot be launched, when ``selectable`` is `false`.
    public let problem: String?

    /// Creates a profile description.
    ///
    /// - Parameters:
    ///   - name: Profile name, equal to the directory name.
    ///   - directory: Profile directory.
    ///   - bundles: Bundle package names the profile loads.
    ///   - exists: Whether the directory exists on disk.
    ///   - selectable: Whether the profile can be launched.
    ///   - problem: Reason the profile is unusable, when it is.
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

/// How a profile relates to the current startup selection.
public enum HarnessProfileStatus: String, Codable, Equatable, Sendable {
    /// The profile is the one currently selected.
    case active
    /// The profile is selected for the next launch but is not active yet.
    case pending
    /// The profile last known to start successfully.
    case lastKnownGood
    /// The profile is selectable but not otherwise special.
    case ready
    /// The profile cannot be launched.
    case invalid

    /// A localized label for the status.
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

/// The persisted profile selection used to decide what starts next.
public struct HarnessProfileSelection: Codable, Equatable, Sendable {
    /// The selection schema this app writes; other versions are treated as absent.
    public static let currentVersion = 1

    /// Schema version of the stored selection.
    public let version: Int
    /// Profile that is currently running.
    public let active: String
    /// Profile requested for the next launch, when it differs from ``active``.
    public let pending: String?
    /// Profile used as a fallback when the requested profile fails to start.
    public let lastKnownGood: String

    /// Creates a selection record.
    ///
    /// - Parameters:
    ///   - version: Schema version; defaults to ``currentVersion``.
    ///   - active: Profile that is currently running.
    ///   - pending: Profile requested for the next launch, if any.
    ///   - lastKnownGood: Fallback profile for a failed start.
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

    /// Whether every recorded profile name passes the store's safety check.
    public var isValid: Bool {
        version == Self.currentVersion
            && HarnessProfileStore.isSafeName(active)
            && HarnessProfileStore.isSafeName(lastKnownGood)
            && (pending == nil || HarnessProfileStore.isSafeName(pending!))
    }
}

/// Failures raised while creating, selecting, or deleting a profile.
public enum HarnessProfileStoreError: Error, Equatable, LocalizedError, Sendable {
    /// The requested name is not usable as a profile directory name.
    case invalidName
    /// A profile with that name already exists.
    case alreadyExists
    /// No profile exists for the requested name.
    case notFound
    /// The profile exists but cannot be launched; carries the reason.
    case notSelectable(String)
    /// The profile is active, pending, or the last known good one, so it must be kept.
    case cannotDeleteActive
    /// The profile manifest could not be parsed; carries the detail.
    case malformedManifest(String)
    /// The selection state could not be written; carries the detail.
    case persistenceFailed(String)

    /// A localized, user-facing description of the failure.
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
