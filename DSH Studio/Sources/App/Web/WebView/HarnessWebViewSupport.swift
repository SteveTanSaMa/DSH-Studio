//
//  HarnessWebViewSupport.swift
//  DSH Studio
//

import WebKit

/// Weak registry entry used to stop all live WebViews before app termination.
final class WeakWebView {
    /// The registered WebView; the reference is weak so registration cannot keep it alive.
    weak var value: WKWebView?

    /// Registers a WebView.
    ///
    /// - Parameter value: WebView to observe weakly.
    init(_ value: WKWebView) {
        self.value = value
    }
}
