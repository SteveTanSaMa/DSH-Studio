//
//  AppSettingsWebState.swift
//  DSH Studio
//

import Foundation

/// Snapshot of the app-owned settings shown inside Harness's settings page.
///
/// Paths are tilde-abbreviated because the page displays them verbatim.
struct AppSettingsWebState: Codable, Equatable, Sendable {
    /// Selected workspace, tilde-abbreviated for display.
    let workspacePath: String
    /// Chat content width in CSS pixels; already clamped by ``SettingsStore``.
    let chatContentMaxWidth: Double
    /// Harness data home, tilde-abbreviated for display.
    let dshHomePath: String
    /// Raw value of the turn-completion preference.
    let turnCompletionNotification: String
    /// Whether permission notifications are enabled.
    let permissionNotificationsEnabled: Bool
    /// Whether question notifications are enabled.
    let questionNotificationsEnabled: Bool
}
