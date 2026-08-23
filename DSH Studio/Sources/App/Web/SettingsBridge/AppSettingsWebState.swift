//
//  AppSettingsWebState.swift
//  DSH Studio
//

import Foundation

struct AppSettingsWebState: Codable, Equatable, Sendable {
    let workspacePath: String
    let chatContentMaxWidth: Double
    let dshHomePath: String
    let runtimeError: String?
    let harnessVersion: String?
    let latestHarnessVersion: String?
    let runtimeUpdateAvailable: Bool
    let turnCompletionNotification: String
    let permissionNotificationsEnabled: Bool
    let questionNotificationsEnabled: Bool
}
