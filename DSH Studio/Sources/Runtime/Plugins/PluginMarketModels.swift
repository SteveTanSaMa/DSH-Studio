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
    /// The npm package name installed into the Harness profile.
    public static let packageName = "dshmarket"
    /// The pinned package version; the market is never resolved from a moving tag.
    public static let packageVersion = "1.46.1"
    /// The only profile allowed to host the market.
    public static let profileName = "web"
    /// The single registry host accepted by ``registryURL``.
    public static let registryHost = "registry.npmjs.org"
    /// Registry base URL used for the pinned install.
    ///
    /// The host is fixed so a profile override cannot redirect the install.
    public static let registryURL = URL(string: "https://registry.npmjs.org")!
    /// The expected `sha512` integrity recorded in the profile lockfile.
    public static let packageIntegrity = "sha512-TtQbcCXhaWMiq6rElNg7EtckkPD8JxMfOvbxU4WxN9amQVqnqVsCqfuA9Cq1iZTVQeh59vK6brI7oIl9S+/JsA=="
    /// The Harness version the pinned package was verified against.
    ///
    /// Retained for compatibility with the existing state model. Installation is
    /// governed by the fixed Plugin Market package contract above.
    public static let compatibleHarnessVersion = RuntimeRelease.harnessVersion
    /// Provenance text shown next to the installed version.
    public static let sourceDescription = "npmjs.com / dshmarket@1.46.1"
}

/// Where the market package stands on this machine.
///
/// The value is a native projection derived from the Harness profile and the
/// market's own health route; the market's inventory is never copied into it.
public enum PluginMarketInstallState: String, Codable, Equatable, Sendable {
    /// The profile is being inspected; no verdict is available yet.
    case checking
    /// Harness is not ready, so the package could not be inspected.
    case runtimeUnavailable
    /// No market package is present in the profile.
    case notInstalled
    /// The pinned version is installed, enabled, and answering.
    case installed
    /// The package is present but its profile patch is disabled.
    case disabled
    /// The running Harness version does not match the pinned contract.
    case incompatible
    /// A package directory exists but its manifest, patch, or lockfile is invalid.
    case corrupted
    /// Harness is ready but the market route did not answer.
    case unavailable
}

/// A market lifecycle action the app can request.
///
/// Each case maps to one profile mutation; the manager rejects a second
/// request while another is in flight.
public enum PluginMarketOperation: String, Codable, Equatable, Sendable {
    /// Installs the pinned package into the profile for the first time.
    case install
    /// Moves an existing installation to the pinned version.
    case update
    /// Re-activates a disabled profile patch.
    case enable
    /// Keeps the package on disk but removes it from the profile.
    case disable
    /// Removes the package and its profile entry.
    case uninstall
    /// Reinstalls a corrupted or incomplete installation.
    case repair
}

/// The outcome of the most recent market operation.
///
/// The record is written to `last-operation.json` under the app support
/// directory, so a failure that happened before the window opened can still
/// be explained after a relaunch.
public struct PluginMarketOperationRecord: Codable, Equatable, Sendable {
    /// The action that was attempted.
    public let operation: PluginMarketOperation
    /// Whether the action completed without throwing.
    public let succeeded: Bool
    /// The failure description, or `完成` when the action succeeded.
    public let message: String
    /// When the attempt finished.
    public let date: Date

    /// Creates a record for one finished attempt.
    ///
    /// - Parameters:
    ///   - operation: The attempted action.
    ///   - succeeded: Whether the action completed without throwing.
    ///   - message: Failure detail, or a short success note.
    ///   - date: Completion time; defaults to now.
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

/// A native projection of the market's state.
///
/// The full market inventory is intentionally not copied here; it remains owned
/// by dsh-market's own Web UI.
public struct PluginMarketState: Codable, Equatable, Sendable {
    /// The verdict of the last inspection; decides which actions are offered.
    public let installState: PluginMarketInstallState
    /// The package this state describes.
    public let packageName: String
    /// The pinned version the app installs, independent of what is on disk.
    public let requestedVersion: String
    /// The version found in the profile, or `nil` when none is installed.
    public let installedVersion: String?
    /// The newest version the market reported.
    ///
    /// Falls back to the version served by the market's status route when the
    /// update feed has no entry for the package.
    public let latestVersion: String?
    /// Whether the market's update feed reports a newer version than the pinned one.
    public let updateAvailable: Bool
    /// Whether the running Harness matches the version the pinned package supports.
    public let compatibleHarness: Bool
    /// Whether the profile patch currently activates the market.
    public let enabled: Bool
    /// Whether the market's HTTP route answered while Harness was ready.
    public let routeAvailable: Bool
    /// Whether the market reports an operation in progress.
    public let busy: Bool
    /// The profile hosting the market.
    public let profileName: String
    /// Absolute path of the hosting profile, shown in diagnostics.
    public let profileDirectory: String
    /// Provenance text for the installed package.
    public let source: String
    /// The integrity string the profile lockfile is validated against.
    public let integrity: String
    /// The last inspection or operation error, or `nil` when healthy.
    public let statusError: String?
    /// The most recent operation record, restored from disk on launch.
    public let lastOperation: PluginMarketOperationRecord?

    /// Creates a state snapshot.
    ///
    /// Every parameter defaults to the pinned contract in ``PluginMarketRelease``,
    /// so a partially inspected profile still produces a well-formed state.
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

/// The payload of the market's `/status` route.
///
/// Every field is optional because the route is served by a third-party
/// package: a missing key must not fail decoding.
public struct PluginMarketHTTPStatus: Codable, Equatable, Sendable {
    /// Whether the market considers itself active.
    public let active: Bool?
    /// Whether the market is running an operation of its own.
    public let busy: Bool?
    /// The version the market reports for itself.
    public let version: String?
    /// An error the market wants surfaced in the app.
    public let error: String?
    /// Whether the market is asking the app to restart Harness.
    public let restart: Bool?
    /// Installed plugin versions keyed by package name.
    public let installed: [String: String]?

    /// Creates a status payload; fields left out decode as `nil`.
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

/// One entry of the market's `/updates` feed.
///
/// Optional fields keep the model tolerant of feed revisions.
public struct PluginMarketUpdateStatus: Codable, Equatable, Sendable {
    /// The update channel kind reported by the feed.
    public let kind: String?
    /// The candidate version for this entry.
    public let version: String?
    /// The version currently installed for this entry.
    public let current: String?
    /// The newest version the feed knows about.
    public let latest: String?
    /// Whether the feed considers an update available.
    public let updateAvailable: Bool?
    /// The channel the feed suggests switching to, when it differs from the current one.
    public let channelSwitch: String?

    /// Creates a feed entry; fields left out decode as `nil`.
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

/// The payload of the market's `/updates` route, keyed by package name.
public struct PluginMarketUpdatesResponse: Codable, Equatable, Sendable {
    /// Update entries keyed by package name; the market keys itself as `dsh-market`.
    public let updates: [String: PluginMarketUpdateStatus]

    /// Creates an updates payload from a decoded feed.
    public init(updates: [String: PluginMarketUpdateStatus]) {
        self.updates = updates
    }
}

/// Failures raised while talking to the market's HTTP routes.
///
/// Messages are user-facing and localized by the host app, so cases carry the
/// raw detail rather than a rendered sentence.
public enum PluginMarketHTTPError: Error, Equatable, LocalizedError, Sendable {
    /// The Runtime's ready URL could not be turned into a request URL.
    case invalidBaseURL
    /// The request failed before a response arrived; carries the transport detail.
    case transport(String)
    /// The route answered with a non-success HTTP status and an optional body excerpt.
    case status(Int, String)
    /// The response body did not match the expected JSON shape.
    case invalidResponse(String)

    /// A localized, user-facing description of the failure.
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

/// Failures raised while managing the market's profile installation.
///
/// The associated strings are diagnostic details, not rendered sentences; the
/// localized text is produced by ``errorDescription``.
public enum PluginMarketManagerError: Error, Equatable, LocalizedError, Sendable {
    /// Another market operation is already running.
    case operationInProgress
    /// Harness is provisioning, updating, or stopping.
    case runtimeBusy
    /// Harness has not reported a ready URL yet.
    case runtimeNotReady
    /// The running Harness version differs from the one the market requires.
    case incompatibleHarness(expected: String, actual: String?)
    /// The profile path failed the safety checks; carries the rejected detail.
    case unsafeProfile(String)
    /// The profile manifest or patch could not be parsed.
    case malformedProfile(String)
    /// A profile command (pnpm/node) exited unsuccessfully.
    case commandFailed(String)
    /// An operation failed and restoring the previous profile also failed.
    case recoveryFailed(String)
    /// The market cannot run in the current configuration; carries the reason.
    case unavailable(String)

    /// A localized, user-facing description of the failure.
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
