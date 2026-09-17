//
//  AppSettingsWebBridge.swift
//  DSH Studio
//

import Foundation

/// Bridge for the app-owned settings sections injected into Harness's Settings.
///
/// The injected sections reuse Harness's own DOM and design tokens so the page
/// keeps looking like one product.
enum AppSettingsWebBridge {
    /// Script-message handler name the injected bridge posts to.
    static let messageHandlerName = "deepseekStudio"
    /// The complete bridge script injected into the Harness page.
    ///
    /// Composed from the environment, styles, and behavior parts so each stays
    /// readable on its own.
    static let source = sourcePartOne + sourcePartTwo + sourcePartThree
}
