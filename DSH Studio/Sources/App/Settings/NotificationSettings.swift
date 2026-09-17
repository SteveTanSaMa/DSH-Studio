//
//  NotificationSettings.swift
//  DSH Studio
//

import Foundation

/// Controls when a completed Harness turn should produce a system notification.
enum TurnCompletionNotificationPreference: String, CaseIterable, Sendable {
    /// Completed turns never notify.
    case never
    /// Completed turns always notify.
    case always
    /// Completed turns notify only while the app is not frontmost.
    case whenNotFocused
}

