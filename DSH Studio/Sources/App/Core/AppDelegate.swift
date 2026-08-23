//
//  AppDelegate.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/16.
//

import AppKit
import Foundation
import UserNotifications

/// Bridges AppKit application lifecycle events to the shared app model.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static let sharedModel = AppModel()

    /// Activates the app after launch so the local Harness window is foregrounded.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        UNUserNotificationCenter.current().delegate = self
    }

    /// Delays termination until the child Harness process has stopped cleanly.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let runtime = AppDelegate.sharedModel.runtime
        AppDelegate.sharedModel.stopNotifications()
        HarnessWebView.prepareForTermination()
        Task {
            await runtime.stop()
            await MainActor.run {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    /// Local notifications must explicitly opt into presentation while the app is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
