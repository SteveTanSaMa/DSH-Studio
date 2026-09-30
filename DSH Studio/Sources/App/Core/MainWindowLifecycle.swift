//
//  MainWindowLifecycle.swift
//  DSH Studio
//

import AppKit
import SwiftUI

/// Keeps the main Harness document alive when the user closes its window.
@MainActor
final class MainWindowLifecycle: NSObject, NSWindowDelegate {
    /// The one lifecycle coordinator used by the main Harness window.
    static let shared = MainWindowLifecycle()

    private weak var mainWindow: NSWindow?

    /// Attaches the lifecycle delegate to the window created by the WindowGroup.
    func attach(to window: NSWindow) {
        guard mainWindow !== window else { return }
        if mainWindow?.delegate === self {
            mainWindow?.delegate = nil
        }
        mainWindow = window
        window.delegate = self
    }

    /// Hides the window without tearing down the WebView or Runtime.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow else { return true }
        sender.orderOut(nil)
        return false
    }

    /// Restores the hidden Harness window when the app is activated from the Dock.
    func showMainWindow() {
        guard let mainWindow else { return }
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Exposes the SwiftUI-created NSWindow to the native lifecycle coordinator.
struct MainWindowAccessor: NSViewRepresentable {
    /// Builds the probe view and forwards the window it is attached to.
    ///
    /// - Parameter context: SwiftUI context; unused because the probe reports its own
    ///   window through `viewDidMoveToWindow`.
    /// - Returns: A zero-size view that reports window changes.
    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.onWindowChange = { window in
            MainWindowLifecycle.shared.attach(to: window)
        }
        return view
    }

    /// Re-attaches the delegate when SwiftUI moves the probe to another window.
    ///
    /// - Parameters:
    ///   - nsView: Probe view being updated.
    ///   - context: SwiftUI context; unused.
    func updateNSView(_ nsView: WindowProbeView, context: Context) {
        if let window = nsView.window {
            MainWindowLifecycle.shared.attach(to: window)
        }
    }
}

/// A zero-size AppKit view that observes the window assigned by SwiftUI.
final class WindowProbeView: NSView {
    /// Called with the new window whenever AppKit moves the view into one.
    var onWindowChange: ((NSWindow) -> Void)?

    /// Reports the host window once AppKit has assigned it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onWindowChange?(window)
        }
    }
}
