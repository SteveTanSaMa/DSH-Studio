//
//  PluginMarketModels.swift
//  DSH Studio
//

import Foundation

/// The fixed upstream package installed by DSH Studio.
///
/// Keeping this contract immutable means the app never executes a remote
/// install script or resolves an unbounded npm tag on a user's machine.
public enum PluginMarketRelease {
    public static let packageName = "dshmarket"
    public static let packageVersion = "1.21.2"
    public static let profileName = "web"
    public static let registryHost = "registry.npmjs.org"
    public static let registryURL = URL(string: "https://registry.npmjs.org")!
    public static let packageIntegrity = "sha512-Q+5i9eHvD2R/vm422Qn0fImpkD74VfP7D4ltab0YlQ6cwAvE93ONcVuxz3Iej630PP6FjojUt6G1w4/3LY/kAQ=="
    public static let compatibleHarnessVersion = RuntimeRelease.harnessVersion
    public static let sourceDescription = "npmjs.com / dshmarket@1.21.2"
}

public enum PluginMarketInstallState: String, Codable, Equatable, Sendable {
    case checking
    case runtimeUnavailable
    case notInstalled
    case installed
    case disabled
    case incompatible
    case corrupted
    case unavailable
}

public enum PluginMarketOperation: String, Codable, Equatable, Sendable {
    case install
    case update
    case enable
    case disable
    case uninstall
    case repair
}

public struct PluginMarketOperationRecord: Codable, Equatable, Sendable {
    public let operation: PluginMarketOperation
    public let succeeded: Bool
    public let message: String
    public let date: Date

    public init(
        operation: PluginMarketOperation,
        succeeded: Bool,
        message: String,
        date: Date = Date()
    ) {
        self.operation = operation
        self.succeeded = succeeded
        self.message = message
        self.date = date
    }
}

/// A native projection of the market's state. The full market inventory is
/// intentionally not copied here; it remains owned by dsh-market's Web UI.
public struct PluginMarketState: Codable, Equatable, Sendable {
    public let installState: PluginMarketInstallState
    public let packageName: String
    public let requestedVersion: String
    public let installedVersion: String?
    public let latestVersion: String?
    public let updateAvailable: Bool
    public let compatibleHarness: Bool
    public let enabled: Bool
    public let routeAvailable: Bool
    public let busy: Bool
    public let profileName: String
    public let profileDirectory: String
    public let source: String
    public let integrity: String
    public let statusError: String?
    public let lastOperation: PluginMarketOperationRecord?

    public init(
        installState: PluginMarketInstallState = .checking,
        packageName: String = PluginMarketRelease.packageName,
        requestedVersion: String = PluginMarketRelease.packageVersion,
        installedVersion: String? = nil,
        latestVersion: String? = nil,
        updateAvailable: Bool = false,
        compatibleHarness: Bool = false,
        enabled: Bool = false,
        routeAvailable: Bool = false,
        busy: Bool = false,
        profileName: String = PluginMarketRelease.profileName,
        profileDirectory: String = "",
        source: String = PluginMarketRelease.sourceDescription,
        integrity: String = PluginMarketRelease.packageIntegrity,
        statusError: String? = nil,
        lastOperation: PluginMarketOperationRecord? = nil
    ) {
        self.installState = installState
        self.packageName = packageName
        self.requestedVersion = requestedVersion
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.updateAvailable = updateAvailable
        self.compatibleHarness = compatibleHarness
        self.enabled = enabled
        self.routeAvailable = routeAvailable
        self.busy = busy
        self.profileName = profileName
        self.profileDirectory = profileDirectory
        self.source = source
        self.integrity = integrity
        self.statusError = statusError
        self.lastOperation = lastOperation
    }
}

public struct PluginMarketHTTPStatus: Codable, Equatable, Sendable {
    public let active: Bool?
    public let busy: Bool?
    public let version: String?
    public let error: String?
    public let restart: Bool?
    public let installed: [String: String]?

    public init(
        active: Bool? = nil,
        busy: Bool? = nil,
        version: String? = nil,
        error: String? = nil,
        restart: Bool? = nil,
        installed: [String: String]? = nil
    ) {
        self.active = active
        self.busy = busy
        self.version = version
        self.error = error
        self.restart = restart
        self.installed = installed
    }
}

public struct PluginMarketUpdateStatus: Codable, Equatable, Sendable {
    public let kind: String?
    public let version: String?
    public let current: String?
    public let latest: String?
    public let updateAvailable: Bool?
    public let channelSwitch: String?

    public init(
        kind: String? = nil,
        version: String? = nil,
        current: String? = nil,
        latest: String? = nil,
        updateAvailable: Bool? = nil,
        channelSwitch: String? = nil
    ) {
        self.kind = kind
        self.version = version
        self.current = current
        self.latest = latest
        self.updateAvailable = updateAvailable
        self.channelSwitch = channelSwitch
    }
}

public struct PluginMarketUpdatesResponse: Codable, Equatable, Sendable {
    public let updates: [String: PluginMarketUpdateStatus]

    public init(updates: [String: PluginMarketUpdateStatus]) {
        self.updates = updates
    }
}

public enum PluginMarketHTTPError: Error, Equatable, LocalizedError, Sendable {
    case invalidBaseURL
    case transport(String)
    case status(Int, String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Plugin Market 地址不可用"
        case .transport(let detail):
            return "Plugin Market 请求失败：\(detail)"
        case .status(let code, let detail):
            return detail.isEmpty
                ? "Plugin Market 返回 HTTP \(code)"
                : "Plugin Market 返回 HTTP \(code)：\(detail)"
        case .invalidResponse(let detail):
            return "Plugin Market 响应无效：\(detail)"
        }
    }
}

public enum PluginMarketManagerError: Error, Equatable, LocalizedError, Sendable {
    case operationInProgress
    case runtimeBusy
    case runtimeNotReady
    case incompatibleHarness(expected: String, actual: String?)
    case unsafeProfile(String)
    case malformedProfile(String)
    case commandFailed(String)
    case recoveryFailed(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "Plugin Market 正在执行另一个操作"
        case .runtimeBusy:
            return "Runtime 当前正在执行其他操作"
        case .runtimeNotReady:
            return "Runtime 尚未就绪"
        case .incompatibleHarness(let expected, let actual):
            return "Harness 版本不兼容：需要 \(expected)，当前为 \(actual ?? "未知")"
        case .unsafeProfile(let detail):
            return "Plugin Market Profile 路径不安全：\(detail)"
        case .malformedProfile(let detail):
            return "Plugin Market Profile 配置无效：\(detail)"
        case .commandFailed(let detail):
            return "Plugin Market 命令失败：\(detail)"
        case .recoveryFailed(let detail):
            return "Plugin Market 恢复失败：\(detail)"
        case .unavailable(let detail):
            return "Plugin Market 不可用：\(detail)"
        }
    }
}
