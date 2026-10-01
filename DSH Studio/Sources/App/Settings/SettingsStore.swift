//
//  SettingsStore.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import Combine
import DeepSeekRuntime
import Foundation

/// The app's startup mirror of the settings Harness owns.
///
/// Ownership, in one place:
///
/// - **Harness Settings is the authoritative persisted configuration.** Everything a
///   user configures lives in the `dsh-studio` namespace and is written through
///   Harness's settings service, fenced by the namespace revision.
/// - **This store is a startup mirror.** Three of the values have to be known before
///   Harness can start — the layout width the injected CSS uses and the two
///   notification switches — and Harness's settings document is only readable once its
///   local server is up. The store also survives the case where the Runtime is not
///   installed yet, or the settings plugin is not present in the active profile.
/// - **The mirror must never overwrite authoritative Harness settings after the
///   initial migration.** A normal launch reads the namespace and adopts it
///   (``adopt(_:)``); the only value it publishes is the workspace, which the app owns
///   because only it can admit a directory and relaunch Harness against it
///   (``legacyPluginEnvironment`` carries the one-time migration of legacy values).
@MainActor
final class SettingsStore: ObservableObject {
    /// Defaults key for the chat content width.
    static let chatContentMaxWidthKey = "chatContentMaxWidth"
    /// Width used when nothing is stored.
    static let chatContentMaxWidthDefault = 1000.0
    /// Accepted width range; the lower bound keeps the chat column usable.
    static let chatContentMaxWidthRange = 748.0...2400.0
    /// Step offered by width controls.
    static let chatContentMaxWidthStep = 16.0
    /// Defaults key for the turn-completion notification preference.
    static let turnCompletionNotificationKey = "turnCompletionNotification"
    /// Preference used when nothing is stored.
    static let turnCompletionNotificationDefault = TurnCompletionNotificationPreference.whenNotFocused
    /// Defaults key for permission notifications.
    static let permissionNotificationsEnabledKey = "permissionNotificationsEnabled"
    /// Whether permission notifications are on by default.
    static let permissionNotificationsEnabledDefault = true
    /// Defaults key for question notifications.
    static let questionNotificationsEnabledKey = "questionNotificationsEnabled"
    /// Whether question notifications are on by default.
    static let questionNotificationsEnabledDefault = true
    /// Defaults key for the selected workspace path.
    static let workspacePathKey = "workspacePath"
    /// Defaults key for the sidebar width the user dragged to.
    static let sidebarWidthKey = "sidebarWidth"
    /// Range the sidebar accepts, mirroring the Harness layout contract's drag clamp.
    static let sidebarWidthRange = 264.0...420.0

    private let defaults: UserDefaults

    /// The workspace is user-selectable; DSH_HOME remains app-owned.
    @Published var workspaceURL: URL {
        didSet {
            defaults.set(workspaceURL.standardizedFileURL.path, forKey: Self.workspacePathKey)
        }
    }
    /// App-owned Harness data home; it is never user-selectable.
    let dshHomeURL: URL

    /// Maximum width of the chat content area, in CSS pixels.
    ///
    /// Values are clamped to ``chatContentMaxWidthRange`` on write, so a stored or
    /// WebView-provided value can never reach the page out of range.
    @Published var chatContentMaxWidth: Double {
        didSet {
            let normalized = Self.normalizedChatContentMaxWidth(chatContentMaxWidth)
            if normalized != chatContentMaxWidth {
                chatContentMaxWidth = normalized
                return
            }
            defaults.set(normalized, forKey: Self.chatContentMaxWidthKey)
        }
    }

    /// When a completed turn should raise a system notification.
    @Published var turnCompletionNotification: TurnCompletionNotificationPreference {
        didSet {
            defaults.set(turnCompletionNotification.rawValue, forKey: Self.turnCompletionNotificationKey)
        }
    }

    /// Whether notifications about permission requests are enabled.
    @Published var permissionNotificationsEnabled: Bool {
        didSet {
            defaults.set(permissionNotificationsEnabled, forKey: Self.permissionNotificationsEnabledKey)
        }
    }

    /// Whether notifications about pending questions are enabled.
    @Published var questionNotificationsEnabled: Bool {
        didSet {
            defaults.set(questionNotificationsEnabled, forKey: Self.questionNotificationsEnabledKey)
        }
    }

    /// Width the sidebar was last dragged to, in CSS pixels.
    ///
    /// The Harness layout store keeps panel geometry in memory only — its own contract
    /// calls those preferences transient — so a width the user dragged would be gone on
    /// the next launch. The app remembers it and hands it back to the page at document
    /// start, which replays it through the same drag the user performed.
    ///
    /// `nil` until the page reports a width, which is what keeps a first launch from
    /// pushing a value the user never chose.
    @Published var sidebarWidth: Double? {
        didSet {
            guard let sidebarWidth else {
                defaults.removeObject(forKey: Self.sidebarWidthKey)
                return
            }
            let normalized = Self.normalizedSidebarWidth(sidebarWidth)
            if normalized != sidebarWidth {
                self.sidebarWidth = normalized
                return
            }
            defaults.set(normalized, forKey: Self.sidebarWidthKey)
        }
    }

    /// Loads every app-owned preference, falling back to the documented defaults.
    ///
    /// A stored workspace that no longer passes admission is replaced by the default
    /// workspace instead of being trusted.
    ///
    /// - Parameter defaults: Defaults domain to read; injectable for tests.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let defaultWorkspace = RuntimeLocator.defaultWorkspace()
            ?? RuntimeLocator.applicationSupportDirectory()!
                .appendingPathComponent("Workspace", isDirectory: true)
        workspaceURL = WorkspaceAdmission.persistedURL(
            from: defaults.string(forKey: Self.workspacePathKey)
        ) ?? defaultWorkspace
        dshHomeURL = RuntimeLocator.defaultDSHHome()
            ?? RuntimeLocator.applicationSupportDirectory()!
                .appendingPathComponent("DSH_HOME", isDirectory: true)
        let storedWidth = (defaults.object(forKey: Self.chatContentMaxWidthKey) as? NSNumber)?.doubleValue
        chatContentMaxWidth = Self.normalizedChatContentMaxWidth(storedWidth)
        turnCompletionNotification = Self.normalizedTurnCompletionNotification(
            defaults.string(forKey: Self.turnCompletionNotificationKey)
        )
        permissionNotificationsEnabled = defaults.object(
            forKey: Self.permissionNotificationsEnabledKey
        ) as? Bool ?? Self.permissionNotificationsEnabledDefault
        questionNotificationsEnabled = defaults.object(
            forKey: Self.questionNotificationsEnabledKey
        ) as? Bool ?? Self.questionNotificationsEnabledDefault
        sidebarWidth = (defaults.object(forKey: Self.sidebarWidthKey) as? NSNumber)
            .map { Self.normalizedSidebarWidth($0.doubleValue) }
    }

    /// Clamps a width to the supported range.
    ///
    /// - Parameter value: Candidate width; non-finite or missing values fall back to
    ///   ``chatContentMaxWidthDefault``.
    /// - Returns: A width inside ``chatContentMaxWidthRange``.
    static func normalizedChatContentMaxWidth(_ value: Double?) -> Double {
        // Clamp persisted or WebView-provided values before they affect CSS.
        guard let value, value.isFinite else { return chatContentMaxWidthDefault }
        return min(max(value, chatContentMaxWidthRange.lowerBound), chatContentMaxWidthRange.upperBound)
    }

    /// Clamps a width to the supported range.
    ///
    /// - Parameter value: Candidate width; non-finite values fall back to the range's
    ///   lower bound, which is the narrowest sidebar the layout accepts.
    /// - Returns: A width inside ``sidebarWidthRange``.
    static func normalizedSidebarWidth(_ value: Double) -> Double {
        guard value.isFinite else { return sidebarWidthRange.lowerBound }
        return min(max(value, sidebarWidthRange.lowerBound), sidebarWidthRange.upperBound)
    }

    /// Resolves a stored notification preference.
    ///
    /// - Parameter value: Raw stored value.
    /// - Returns: The matching preference, or ``turnCompletionNotificationDefault``
    ///   when the value is missing or unrecognized.
    static func normalizedTurnCompletionNotification(
        _ value: String?
    ) -> TurnCompletionNotificationPreference {
        guard let value,
              let preference = TurnCompletionNotificationPreference(rawValue: value) else {
            return turnCompletionNotificationDefault
        }
        return preference
    }

    /// The five shared preferences as this store currently holds them.
    var studioSettingsSnapshot: StudioSettingsSnapshot {
        StudioSettingsSnapshot(
            workspacePath: workspaceURL.standardizedFileURL.path,
            chatContentMaxWidth: chatContentMaxWidth,
            turnCompletionNotification: turnCompletionNotification.rawValue,
            permissionNotificationsEnabled: permissionNotificationsEnabled,
            questionNotificationsEnabled: questionNotificationsEnabled
        )
    }

    /// Adopts the values Harness owns.
    ///
    /// A field Harness did not supply, and the workspace it may hold, are left as they
    /// are: adoption only ever follows the authoritative settings.
    ///
    /// - Parameter snapshot: Values read from the DSH Studio namespace.
    /// - Returns: Whether the width changed, so the caller can re-apply the injected CSS.
    @discardableResult
    func adopt(_ snapshot: StudioSettingsSnapshot) -> Bool {
        let previousWidth = chatContentMaxWidth
        if let width = snapshot.chatContentMaxWidth {
            chatContentMaxWidth = width
        }
        if let raw = snapshot.turnCompletionNotification,
           let preference = TurnCompletionNotificationPreference(rawValue: raw) {
            turnCompletionNotification = preference
        }
        if let enabled = snapshot.permissionNotificationsEnabled {
            permissionNotificationsEnabled = enabled
        }
        if let enabled = snapshot.questionNotificationsEnabled {
            questionNotificationsEnabled = enabled
        }
        return chatContentMaxWidth != previousWidth
    }

    /// Encodes only the five legacy preference fields for the one-launch
    /// migration handoff to the first-party Harness settings plugin.
    var legacyPluginEnvironment: [String: String] {
        let values: [String: Any] = [
            Self.workspacePathKey: workspaceURL.standardizedFileURL.path,
            Self.chatContentMaxWidthKey: chatContentMaxWidth,
            Self.turnCompletionNotificationKey: turnCompletionNotification.rawValue,
            Self.permissionNotificationsEnabledKey: permissionNotificationsEnabled,
            Self.questionNotificationsEnabledKey: questionNotificationsEnabled,
        ]
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values),
              let json = String(data: data, encoding: .utf8) else {
            return [:]
        }
        return ["DSH_STUDIO_LEGACY_PREFERENCES": json]
    }
}
