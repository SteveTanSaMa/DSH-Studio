//
//  AppSettingsWebState.swift
//  DSH Studio
//

import Foundation

struct AppSettingsProfileState: Codable, Equatable, Sendable {
    let name: String
    let selectable: Bool
    let exists: Bool
    let problem: String?
}

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
    let harnessProfileName: String
    let harnessProfiles: [AppSettingsProfileState]
}
