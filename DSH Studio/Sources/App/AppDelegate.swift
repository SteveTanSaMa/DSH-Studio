//
//  AppDelegate.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/16.
//

import AppKit
import Foundation

/// Bridges AppKit application lifecycle events to the shared app model.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let sharedModel = AppModel()

    /// Activates the app after launch so the local Harness window is foregrounded.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Delays termination until the child Harness process has stopped cleanly.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let runtime = AppDelegate.sharedModel.runtime
        HarnessWebView.prepareForTermination()
        Task {
            await runtime.stop()
            await MainActor.run {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}
