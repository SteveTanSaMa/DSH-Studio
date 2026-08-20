//
//  HarnessWebView.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import AppKit
import Combine
import DeepSeekHarness
import DeepSeekLogging
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
        guard let url = runtime.readyURL, webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }

    /// Owns WebKit delegates and serializes bridge requests on MainActor.
    ///
    /// `allowedURL` is refreshed whenever RuntimeManager publishes a new port;
    /// all navigation and API bridge decisions compare against that exact URL.
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var runtime: RuntimeManager
        let model: AppModel
        var allowedURL: URL?
        var onWebContentTerminated: () -> Void
        weak var webView: WKWebView?
        private var reloadAttempts = 0
        // The export extension owns the workflow; the client lives here so the
        // coordinator keeps one staging directory and one cleanup owner.
        let sessionLogClient = SessionLogDownloadClient()
        private var modelCancellable: AnyCancellable?

        init(
            runtime: RuntimeManager,
            model: AppModel,
            onWebContentTerminated: @escaping () -> Void
        ) {
            self.runtime = runtime
            self.model = model
            self.onWebContentTerminated = onWebContentTerminated
            super.init()
            modelCancellable = model.objectWillChange.sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.broadcastAppSettingsState()
                }
            }
        }

        deinit {
            modelCancellable?.cancel()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // JavaScript messages are untrusted input. Parse only the expected
            // dictionary shape, then handle the request on the main actor.
            guard message.name == AppSettingsWebBridge.messageHandlerName,
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else {
                return
            }
            let requestID = body["requestId"] as? String
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                await self.handleAppSettingsMessage(
                    type: type,
                    requestID: requestID,
                    body: body,
                    webView: webView
                )
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Session export is the one Harness download handled natively. All
            // other remote URLs are handed to the default macOS browser.
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
            NSWorkspace.shared.open(url)
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
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
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

        @MainActor
        private func handleAppSettingsMessage(
            type: String,
            requestID: String?,
            body: [String: Any],
            webView: WKWebView
        ) async {
            // Keep the bridge protocol explicit so unknown JavaScript actions
            // fail closed instead of being silently ignored.
            switch type {
            case "appSettings.request":
                sendAppSettingsReply(requestID: requestID, webView: webView)
            case "appSettings.update":
                do {
                    try applyAppSetting(key: body["key"] as? String, value: body["value"])
                    sendAppSettingsReply(
                        requestID: requestID,
                        webView: webView
                    )
                } catch let error as AppSettingsBridgeError {
                    sendAppSettingsReply(
                        requestID: requestID,
                        errorCode: error.code,
                        errorMessage: error.message,
                        webView: webView
                    )
                } catch {
                    sendAppSettingsReply(
                        requestID: requestID,
                        errorCode: "app-settings-save-failed",
                        errorMessage: error.localizedDescription,
                        webView: webView
                    )
                }
            case "appSettings.chooseWorkspace":
                await chooseWorkspace(requestID: requestID, webView: webView)
            case "appSettings.chooseDSHHome":
                await chooseDSHHome(requestID: requestID, webView: webView)
            case "appSettings.openLogs":
                if model.openLogs() {
                    sendAppSettingsReply(
                        requestID: requestID,
                        webView: webView
                    )
                } else {
                    sendAppSettingsReply(
                        requestID: requestID,
                        errorCode: "logs-open-failed",
                        errorMessage: "无法打开日志",
                        webView: webView
                    )
                }
            case "appSettings.runtimeCheck":
                guard let coordinator = model.runtime.runtimeUpdateCoordinator else {
                    sendAppSettingsReply(
                        requestID: requestID,
                        errorCode: "runtime-update-unavailable",
                        errorMessage: "当前 Runtime 不支持在线更新",
                        webView: webView
                    )
                    return
                }
                _ = coordinator.checkVersion()
                sendAppSettingsReply(requestID: requestID, webView: webView)
            case "appSettings.runtimeUpdate":
                await performRuntimeUpdate(requestID: requestID, webView: webView)
            case "appSettings.runtimeRollback":
                await performRuntimeRollback(requestID: requestID, webView: webView)
            default:
                sendAppSettingsReply(
                    requestID: requestID,
                    errorCode: "unknown-app-settings-message",
                    errorMessage: "未知的设置请求",
                    webView: webView
                )
            }
        }

        @MainActor
        private func performRuntimeUpdate(requestID: String?, webView: WKWebView) async {
            guard let coordinator = model.runtime.runtimeUpdateCoordinator else {
                sendAppSettingsReply(
                    requestID: requestID,
                    errorCode: "runtime-update-unavailable",
                    errorMessage: "当前 Runtime 不支持在线更新",
                    webView: webView
                )
                return
            }
            do {
                try await coordinator.update()
                sendAppSettingsReply(requestID: requestID, webView: webView)
            } catch {
                sendAppSettingsReply(
                    requestID: requestID,
                    errorCode: "runtime-update-failed",
                    errorMessage: LogRedactor.redact(error.localizedDescription),
                    webView: webView
                )
            }
        }

        @MainActor
        private func performRuntimeRollback(requestID: String?, webView: WKWebView) async {
            guard let coordinator = model.runtime.runtimeUpdateCoordinator else {
                sendAppSettingsReply(
                    requestID: requestID,
                    errorCode: "runtime-update-unavailable",
                    errorMessage: "当前 Runtime 不支持在线更新",
                    webView: webView
                )
                return
            }
            do {
                try await coordinator.rollback()
                sendAppSettingsReply(requestID: requestID, webView: webView)
            } catch {
                sendAppSettingsReply(
                    requestID: requestID,
                    errorCode: "runtime-rollback-failed",
                    errorMessage: LogRedactor.redact(error.localizedDescription),
                    webView: webView
                )
            }
        }

        @MainActor
        private func applyAppSetting(key: String?, value: Any?) throws {
            guard let key else {
                throw AppSettingsBridgeError(code: "invalid-app-setting", message: "缺少设置名称")
            }
            switch key {
            case "chatContentMaxWidth":
                guard let number = value as? NSNumber else {
                    throw AppSettingsBridgeError(code: "invalid-app-setting", message: "对话最大宽度设置值无效")
                }
                let width = number.doubleValue
                guard width.isFinite,
                      SettingsStore.chatContentMaxWidthRange.contains(width) else {
                    throw AppSettingsBridgeError(
                        code: "invalid-app-setting",
                        message: "对话最大宽度必须在 748 到 2400 像素之间"
                    )
                }
                model.settings.chatContentMaxWidth = width
            default:
                throw AppSettingsBridgeError(code: "unknown-app-setting", message: "不支持的应用设置：\(key)")
            }
        }

        @MainActor
        private func chooseWorkspace(requestID: String?, webView: WKWebView) async {
            let selectedURL = await chooseDirectory(
                initialURL: model.settings.workspaceURL,
                webView: webView
            )
            guard let selectedURL else {
                sendAppSettingsReply(
                    requestID: requestID,
                    cancelled: true,
                    webView: webView
                )
                return
            }

            await model.changeWorkspaceAndWait(to: selectedURL)
            sendAppSettingsReply(
                requestID: requestID,
                webView: webView
            )
        }

        @MainActor
        private func chooseDSHHome(requestID: String?, webView: WKWebView) async {
            let selectedURL = await chooseDirectory(
                initialURL: model.settings.dshHomeURL,
                webView: webView
            )
            guard let selectedURL else {
                sendAppSettingsReply(
                    requestID: requestID,
                    cancelled: true,
                    webView: webView
                )
                return
            }

            await model.changeDSHHomeAndWait(to: selectedURL)
            sendAppSettingsReply(
                requestID: requestID,
                webView: webView
            )
        }

        @MainActor
        private func chooseDirectory(initialURL: URL, webView: WKWebView) async -> URL? {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.directoryURL = initialURL
            return await withCheckedContinuation { continuation in
                if let window = webView.window {
                    panel.beginSheetModal(for: window) { response in
                        continuation.resume(returning: response == .OK ? panel.url : nil)
                    }
                } else {
                    let response = panel.runModal()
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            }
        }

        @MainActor
        private func broadcastAppSettingsState() {
            guard let webView else { return }
            sendAppSettingsReply(requestID: nil, webView: webView)
        }

        @MainActor
        private func sendAppSettingsReply(
            requestID: String?,
            message: String? = nil,
            cancelled: Bool? = nil,
            errorCode: String? = nil,
            errorMessage: String? = nil,
            webView: WKWebView
        ) {
            let reply = AppSettingsBridgeReply(
                requestID: requestID,
                ok: errorCode == nil,
                state: appSettingsState(),
                message: message,
                cancelled: cancelled,
                error: errorCode.map {
                    AppSettingsBridgeReply.ErrorPayload(code: $0, message: errorMessage ?? "设置请求失败")
                }
            )
            guard let data = try? JSONEncoder().encode(reply),
                  let json = String(data: data, encoding: .utf8) else {
                return
            }
            webView.evaluateJavaScript(
                "window.__deepseekStudioReceive && window.__deepseekStudioReceive(\(json));"
            )
        }

        @MainActor
        private func appSettingsState() -> AppSettingsWebState {
            let currentRuntime = model.runtime
            let versionStatus = currentRuntime.runtimeVersionStatus
            return AppSettingsWebState(
                workspacePath: model.settings.workspaceURL.path,
                chatContentMaxWidth: model.settings.chatContentMaxWidth,
                dshHomePath: model.settings.dshHomeURL.path,
                runtimeError: currentRuntime.lastError?.uiDescription,
                harnessVersion: currentRuntime.harnessVersion,
                nodeVersion: currentRuntime.nodeVersion,
                runtimeVersionStatus: versionStatus?.displayName ?? "正在检查",
                runtimeInstalledVersion: versionStatus?.installed?.versionLabel,
                runtimeAvailableVersion: versionStatus?.available.versionLabel,
                runtimeUpdateAvailable: versionStatus?.updateAvailable ?? false,
                runtimeRollbackAvailable: versionStatus?.rollbackAvailable ?? false
            )
        }

        private func isAllowed(_ url: URL) -> Bool {
            // Matching host, scheme, and port prevents a valid loopback URL
            // from being used to reach a different local service.
            guard HarnessURLPolicy.isAllowedLoopback(url),
                  let allowed = allowedURL,
                  HarnessURLPolicy.isAllowedLoopback(allowed) else {
                return false
            }
            return url.scheme == allowed.scheme
                && url.host == allowed.host
                && url.port == allowed.port
        }

    }
}

private struct AppSettingsBridgeError: Error {
    let code: String
    let message: String
}

private struct AppSettingsBridgeReply: Encodable {
    struct ErrorPayload: Encodable {
        let code: String
        let message: String
    }

    let requestID: String?
    let ok: Bool
    let state: AppSettingsWebState
    let message: String?
    let cancelled: Bool?
    let error: ErrorPayload?

    enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case ok
        case state
        case message
        case cancelled
        case error
    }
}

private final class WeakWebView {
    weak var value: WKWebView?

    init(_ value: WKWebView) {
        self.value = value
    }
}
