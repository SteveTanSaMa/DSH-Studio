//
//  HarnessWebViewSupport.swift
//  DSH Studio
//

import WebKit

/// Weak registry entry used to stop all live WebViews before app termination.
final class WeakWebView {
    weak var value: WKWebView?

    init(_ value: WKWebView) {
        self.value = value
    }
}
