//
//  HarnessWebViewNavigation.swift
//  DSH Studio
//

import DeepSeekHarness
import DeepSeekLogging
import Foundation
import WebKit

extension HarnessWebView.Coordinator: WKNavigationDelegate, WKUIDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Session export is the one Harness download handled natively. The
            // embedded UI is loopback-only, so external navigations are
            // cancelled instead of escaping to the system browser.
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
            decisionHandler(.cancel)
        }

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

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            return nil
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            runtime.logs.log(component: "WebView", level: "warn", message: "WebView content process terminated")
            reloadAttempts += 1
            if reloadAttempts <= 1 {
                webView.reload()
            } else {
                onWebContentTerminated()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            reloadAttempts = 0
            self.webView = webView
            broadcastAppSettingsState()
        }

}
