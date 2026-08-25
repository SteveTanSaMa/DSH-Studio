//
//  SettingsStore.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import Combine
import DeepSeekRuntime
import Foundation

@MainActor
/// Persists only app-owned settings; Harness's own settings stay in Harness.
final class SettingsStore: ObservableObject {
    static let chatContentMaxWidthKey = "chatContentMaxWidth"
    static let chatContentMaxWidthDefault = 1000.0
    static let chatContentMaxWidthRange = 748.0...2400.0
    static let chatContentMaxWidthStep = 16.0
    static let turnCompletionNotificationKey = "turnCompletionNotification"
    static let turnCompletionNotificationDefault = TurnCompletionNotificationPreference.whenNotFocused
    static let permissionNotificationsEnabledKey = "permissionNotificationsEnabled"
    static let permissionNotificationsEnabledDefault = true
    static let questionNotificationsEnabledKey = "questionNotificationsEnabled"
    static let questionNotificationsEnabledDefault = true
    static let workspacePathKey = "workspacePath"

    private let defaults: UserDefaults

    /// The workspace is user-selectable; DSH_HOME remains app-owned.
    @Published var workspaceURL: URL {
        didSet {
            defaults.set(workspaceURL.standardizedFileURL.path, forKey: Self.workspacePathKey)
        }
    }
    let dshHomeURL: URL

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

    @Published var turnCompletionNotification: TurnCompletionNotificationPreference {
        didSet {
            defaults.set(turnCompletionNotification.rawValue, forKey: Self.turnCompletionNotificationKey)
        }
    }

    @Published var permissionNotificationsEnabled: Bool {
        didSet {
            defaults.set(permissionNotificationsEnabled, forKey: Self.permissionNotificationsEnabledKey)
        }
    }

    @Published var questionNotificationsEnabled: Bool {
        didSet {
            defaults.set(questionNotificationsEnabled, forKey: Self.questionNotificationsEnabledKey)
        }
    }

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

    static func normalizedChatContentMaxWidth(_ value: Double?) -> Double {
        // Clamp persisted or WebView-provided values before they affect CSS.
        guard let value, value.isFinite else { return chatContentMaxWidthDefault }
        return min(max(value, chatContentMaxWidthRange.lowerBound), chatContentMaxWidthRange.upperBound)
    }

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
