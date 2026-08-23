//
//  HarnessWebView.swift
//  DSH Studio
//

import AppKit
import DeepSeekHarness
import DeepSeekRuntime
import SwiftUI
import WebKit

/// Embeds Harness's loopback Web UI while enforcing the native URL boundary.
///
/// The view owns only WebKit setup and lifecycle. Coordinator behavior is kept
/// below in the same module, while Session export lives in its own extension
/// file to keep this integration surface readable.
struct HarnessWebView: NSViewRepresentable {
    let runtime: RuntimeManager
    let model: AppModel
    let onWebContentTerminated: () -> Void

    private static var liveWebViews: [WeakWebView] = []

    func makeCoordinator() -> Coordinator {
        Coordinator(
            runtime: runtime,
            model: model,
            onWebContentTerminated: onWebContentTerminated
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        // All scripts are main-frame-only so an external page opened by the
        // user cannot inherit DSH Studio's native bridge.
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // macOS WKWebView does not expose its root scroll view through a public
        // API. Overscroll-behavior:none disables root rubber-banding while
        // Harness's own scroll containers keep their normal scrolling.
        let overscroll = "document.documentElement.style.overscrollBehavior='none';document.body.style.overscrollBehavior='none';"
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: SessionLogExportWebBridge.interceptDialogScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController.addUserScript(
            WKUserScript(source: overscroll, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: HarnessLayoutWebBridge.source,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: AppSettingsWebBridge.source,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController.add(context.coordinator, name: AppSettingsWebBridge.messageHandlerName)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        HarnessWebView.register(webView)
        return webView
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        unregister(nsView)
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
        nsView.configuration.userContentController.removeScriptMessageHandler(
            forName: AppSettingsWebBridge.messageHandlerName
        )
    }

    static func prepareForTermination() {
        // Stop navigation before AppKit confirms termination; this avoids a
        // WebKit callback racing RuntimeManager.stop().
        for entry in liveWebViews {
            entry.value?.stopLoading()
        }
    }

    private static func register(_ webView: WKWebView) {
        liveWebViews.append(WeakWebView(webView))
    }

    private static func unregister(_ webView: WKWebView) {
        liveWebViews.removeAll { $0.value === webView }
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.runtime = runtime
        context.coordinator.webView = webView
        context.coordinator.allowedURL = runtime.readyURL
        context.coordinator.onWebContentTerminated = onWebContentTerminated
        guard let url = runtime.readyURL else { return }
        // SwiftUI may call updateNSView for unrelated Runtime/settings changes.
        // Compare the Harness endpoint instead of the full URL: WebKit can add
        // a trailing slash or an SPA route after the initial navigation.
        if sameHarnessEndpoint(webView.url, url) {
            return
        }
        if webView.isLoading {
            webView.stopLoading()
        }
        webView.load(URLRequest(url: url))
    }

    private func sameHarnessEndpoint(_ current: URL?, _ expected: URL) -> Bool {
        guard let current else { return false }
        return current.scheme == expected.scheme
            && current.host == expected.host
            && current.port == expected.port
    }
}
