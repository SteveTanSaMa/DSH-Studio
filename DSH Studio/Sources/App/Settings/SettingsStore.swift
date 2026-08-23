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

    private let defaults: UserDefaults

    /// Workspace and Harness data locations are app-owned fixed locations.
    /// Older custom path values in UserDefaults are intentionally ignored.
    let workspaceURL: URL
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        workspaceURL = RuntimeLocator.defaultWorkspace()
            ?? RuntimeLocator.applicationSupportDirectory()!
                .appendingPathComponent("Workspace", isDirectory: true)
        dshHomeURL = RuntimeLocator.defaultDSHHome()
            ?? RuntimeLocator.applicationSupportDirectory()!
                .appendingPathComponent("DSH_HOME", isDirectory: true)
        let storedWidth = (defaults.object(forKey: Self.chatContentMaxWidthKey) as? NSNumber)?.doubleValue
        chatContentMaxWidth = Self.normalizedChatContentMaxWidth(storedWidth)
    }

    static func normalizedChatContentMaxWidth(_ value: Double?) -> Double {
        // Clamp persisted or WebView-provided values before they affect CSS.
        guard let value, value.isFinite else { return chatContentMaxWidthDefault }
        return min(max(value, chatContentMaxWidthRange.lowerBound), chatContentMaxWidthRange.upperBound)
    }
}
