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
    static let dshHomeKey = "dshHomePath"
    static let chatContentMaxWidthKey = "chatContentMaxWidth"
    static let chatContentMaxWidthDefault = 1200.0
    static let chatContentMaxWidthRange = 748.0...2400.0
    static let chatContentMaxWidthStep = 16.0

    private let defaults: UserDefaults

    @Published var workspaceURL: URL {
        didSet {
            defaults.set(workspaceURL.path, forKey: "workspacePath")
        }
    }

    @Published var dshHomeURL: URL {
        didSet {
            defaults.set(dshHomeURL.path, forKey: Self.dshHomeKey)
        }
    }

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
        // Paths are stored as strings for UserDefaults compatibility and are
        // converted back to directory URLs at the boundary.
        let savedWorkspace = defaults.string(forKey: "workspacePath")
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        workspaceURL = savedWorkspace ?? RuntimeLocator.defaultWorkspace()
            ?? RuntimeLocator.applicationSupportDirectory()!
                .appendingPathComponent("Workspace", isDirectory: true)
        let savedDSHHome = defaults.string(forKey: Self.dshHomeKey)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        dshHomeURL = savedDSHHome ?? RuntimeLocator.defaultDSHHome()
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
