//
//  NotificationSettings.swift
//  DSH Studio
//

import Foundation

/// Controls when a completed Harness turn should produce a system notification.
enum TurnCompletionNotificationPreference: String, CaseIterable, Sendable {
    case never
    case always
    case whenNotFocused
}

