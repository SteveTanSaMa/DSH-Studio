//
//  HarnessWebViewNavigation.swift
//  DSH Studio
//

import AppKit
import DeepSeekHarness
import DeepSeekLogging
import Foundation
import WebKit

/// Enforces the native navigation boundary around the embedded Harness UI.
extension HarnessWebView.Coordinator: WKNavigationDelegate, WKUIDelegate {
        /// Decides whether an in-flight navigation may proceed.
        ///
        /// Session export is the one Harness download handled natively, and every other
        /// external navigation is cancelled rather than escaping to the system browser.
        ///
        /// - Parameters:
        ///   - webView: WebView asking for a decision.
        ///   - navigationAction: Action describing the requested navigation.
        ///   - decisionHandler: Called exactly once with the decision.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Session export is the one Harness download handled natively. The
            // The embedded UI is loopback-only. Safe user-activated HTTPS links
            // may leave through the system browser; all other external navigation
            // remains cancelled here.
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if url.path == "/api/session.export" {
                guard isAllowed(url) else {
                    decisionHandler(.cancel)
                    return
                }
                decisionHandler(.cancel)
                startSessionExport(from: url, webView: webView)
                return
            }
            if isAllowed(url) {
                decisionHandler(.allow)
                return
            }
            if navigationAction.navigationType == .linkActivated,
               HarnessURLPolicy.isAllowedExternalHTTPS(url) {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        /// Applies the same boundary to responses that were not caught in flight.
        ///
        /// - Parameters:
        ///   - webView: WebView asking for a decision.
        ///   - navigationResponse: Response about to be committed.
        ///   - decisionHandler: Called exactly once with the decision.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if let url = navigationResponse.response.url,
               url.path == "/api/session.export",
               isAllowed(url) {
                decisionHandler(.cancel)
                startSessionExport(from: url, webView: webView)
                return
            }
            guard let url = navigationResponse.response.url else {
                decisionHandler(.cancel)
                return
            }
            if isAllowed(url) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        /// Opens safe external links in the system browser instead of creating a second
        /// embedded page that could inherit the Harness session boundary.
        ///
        /// - Parameters:
        ///   - webView: WebView requesting the new window.
        ///   - configuration: Configuration the new WebView would use.
        ///   - navigationAction: Action that requested the window.
        ///   - windowFeatures: Requested window features.
        /// - Returns: Always `nil`, which cancels the request.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url,
               HarnessURLPolicy.isAllowedExternalHTTPS(url) {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        /// Reloads once after a content-process crash, then reports the failure.
        ///
        /// - Parameter webView: WebView whose content process was terminated.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            runtime.logs.log(component: "WebView", level: "warn", message: "WebView content process terminated")
            reloadAttempts += 1
            if reloadAttempts <= 1 {
                webView.reload()
            } else {
                onWebContentTerminated()
            }
        }

        /// Resets the reload budget and replays the app-owned layout values.
        ///
        /// - Parameters:
        ///   - webView: WebView that finished loading.
        ///   - navigation: The completed navigation.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            reloadAttempts = 0
            self.webView = webView
            // The injected layout script only publishes the setter, while the value
            // itself stays in the app's settings, so every completed load replays it.
            let width = model.settings.chatContentMaxWidth
            webView.evaluateJavaScript(
                "window.__deepseekStudioSetChatContentMaxWidth && window.__deepseekStudioSetChatContentMaxWidth(\(width));"
            )
        }

}
