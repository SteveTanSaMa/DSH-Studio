//
//  DeepSeekHarnessSliceApp.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/21.
//

import AppKit
import SwiftUI

/// Defines the single native window that hosts the local Harness Web UI.
@main
struct DeepSeekHarnessSliceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(model: AppDelegate.sharedModel)
                .frame(minWidth: 1024, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 DSH Studio") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }
        }
    }
}
