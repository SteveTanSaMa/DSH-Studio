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
    /// Runtime whose ready URL the WebView attaches to.
    let runtime: RuntimeManager
    /// Model that supplies the app settings projected into the page.
    let model: AppModel
    /// Called when WebKit kills the content process so the host can recover.
    let onWebContentTerminated: () -> Void

    private static var liveWebViews: [WeakWebView] = []

    /// Creates the coordinator that holds this view's delegate state.
    ///
    /// - Returns: A coordinator bound to the current runtime, model, and callback.
    func makeCoordinator() -> Coordinator {
        Coordinator(
            runtime: runtime,
            model: model,
            onWebContentTerminated: onWebContentTerminated
        )
    }

    /// Builds the WebView, installs the bridges, and registers it as live.
    ///
    /// Every injected script is main-frame-only, so a page opened by the user cannot
    /// inherit the app's native bridge.
    ///
    /// - Parameter context: SwiftUI context carrying the coordinator.
    /// - Returns: A configured WebView, or one showing the failure page when the
    ///   Runtime is not ready.
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
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: PluginMarketRestartWebBridge.source,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController.add(context.coordinator, name: AppSettingsWebBridge.messageHandlerName)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        HarnessWebView.register(webView)
        return webView
    }

    /// Tears the WebView down and removes its message handler.
    ///
    /// - Parameters:
    ///   - nsView: WebView being dismantled.
    ///   - coordinator: Coordinator that owned its delegate state.
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        unregister(nsView)
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
        nsView.configuration.userContentController.removeScriptMessageHandler(
            forName: AppSettingsWebBridge.messageHandlerName
        )
    }

    /// Stops every live WebView before AppKit confirms termination.
    ///
    /// Stopping first keeps a WebKit callback from racing the Runtime shutdown.
    static func prepareForTermination() {
        // Stop navigation before AppKit confirms termination; this avoids a
        // WebKit callback racing RuntimeManager.stop().
        for entry in liveWebViews {
            entry.value?.stopLoading()
        }
    }

    /// Reloads every live WebView, dropping the ones already deallocated.
    @MainActor
    static func reloadLiveWebViews() {
        liveWebViews = liveWebViews.filter { $0.value != nil }
        liveWebViews.forEach { $0.value?.reload() }
    }

    /// Toggles the injected sidebar on every live WebView.
    @MainActor
    static func toggleSidebarOnLiveWebViews() {
        liveWebViews = liveWebViews.filter { $0.value != nil }
        liveWebViews.forEach { webView in
            webView.value?.evaluateJavaScript(
                "window.__deepseekStudioToggleSidebar && window.__deepseekStudioToggleSidebar();"
            )
        }
    }

    private static func register(_ webView: WKWebView) {
        liveWebViews.append(WeakWebView(webView))
    }

    private static func unregister(_ webView: WKWebView) {
        liveWebViews.removeAll { $0.value === webView }
    }

    /// Re-points the coordinator at the current Runtime and settings.
    ///
    /// ``SwiftUI`` calls this for unrelated changes too, so the Harness endpoint is
    /// compared instead of the full URL: WebKit may add a trailing slash or a route
    /// after the first navigation.
    ///
    /// - Parameters:
    ///   - webView: WebView being updated.
    ///   - context: SwiftUI context carrying the coordinator.
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
