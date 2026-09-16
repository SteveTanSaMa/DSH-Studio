//
//  AppSettingsWebState.swift
//  DSH Studio
//

import Foundation

struct AppSettingsWebState: Codable, Equatable, Sendable {
    let workspacePath: String
    let chatContentMaxWidth: Double
    let dshHomePath: String
    let turnCompletionNotification: String
    let permissionNotificationsEnabled: Bool
    let questionNotificationsEnabled: Bool
}
