//
//  SettingsStore.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import Combine
import DeepSeekRuntime
import Foundation

/// Persists only app-owned settings; Harness's own settings stay in Harness.
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
}
