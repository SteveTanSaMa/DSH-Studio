//
//  HarnessWebViewSettingsBridge.swift
//  DSH Studio
//

import DeepSeekHarness
import DeepSeekLogging
import Foundation
import WebKit

/// Native side of the WebView message bridge.
///
/// Settings are owned by the first-party Harness settings plugin: the Harness page
/// renders them and persists them through Harness's own settings service. This bridge
/// carries the operations the page cannot perform itself, plus the preference mirror
/// that keeps the native side (layout width, notifications, workspace) in step.
extension HarnessWebView.Coordinator: WKScriptMessageHandler {
    /// Handles one message posted by the injected settings script.
    ///
    /// The body is untrusted input: only the expected dictionary shape is parsed, and
    /// the request is handled on the main actor.
    ///
    /// - Parameters:
    ///   - userContentController: Controller that delivered the message.
    ///   - message: Message whose name and body are validated before use.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // JavaScript messages are untrusted input. Parse only the expected
        // dictionary shape, then handle the request on the main actor.
        guard message.name == PluginMarketRestartWebBridge.messageHandlerName,
              message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            return
        }
        guard let webView, isAllowed(webView.url ?? URL(string: "about:blank")!) else {
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

    @MainActor
    private func handleAppSettingsMessage(
        type: String,
        requestID: String?,
        body: [String: Any],
        webView: WKWebView
    ) async {
        // The WebView owns the DSH Studio settings page rendered inside Harness.
        switch type {
        case PluginMarketRestartWebBridge.messageType:
            model.restartRuntimeForPluginMarket()
        case "dshStudio.action":
            await handleStudioAction(
                action: body["action"] as? String,
                payload: body["payload"] as? [String: Any] ?? [:],
                requestID: requestID,
                webView: webView
            )
        default:
            return
        }
    }

    @MainActor
    private func handleStudioAction(
        action: String?,
        payload: [String: Any],
        requestID: String?,
        webView: WKWebView
    ) async {
        do {
            let result = try await performStudioAction(action: action, payload: payload)
            sendStudioActionReply(requestID: requestID, result: result, webView: webView)
        } catch {
            sendStudioActionReply(
                requestID: requestID,
                error: LogRedactor.redact(error.localizedDescription),
                webView: webView
            )
        }
    }

    /// Performs one settings-page operation and returns its JSON-safe reply.
    ///
    /// - Parameters:
    ///   - action: Action name sent by the page; unknown names are rejected.
    ///   - payload: Action arguments; every value is validated per action.
    /// - Returns: A JSON-serializable value; `NSNull` stands in for absent data so a
    ///   missing optional never suppresses the reply.
    /// - Throws: ``StudioActionError`` when the request is invalid or the operation fails.
    @MainActor
    private func performStudioAction(
        action: String?,
        payload: [String: Any]
    ) async throws -> Any {
        guard let action else { throw StudioActionError.invalidRequest }
        switch action {
        case "profile.list":
            return [
                "active": model.runtime.configuration.profileName,
                "profiles": model.harnessProfiles.profiles().map { profile in
                    [
                        "name": profile.name,
                        "bundles": profile.bundles,
                        "selectable": profile.selectable,
                        "problem": profile.problem ?? NSNull()
                    ] as [String: Any]
                }
            ]
        case "profile.create":
            guard let name = payload["name"] as? String else { throw StudioActionError.invalidRequest }
            try model.createHarnessProfile(name: name)
            return ["ok": true]
        case "profile.select":
            guard let name = payload["name"] as? String else { throw StudioActionError.invalidRequest }
            _ = try await model.selectHarnessProfile(name: name)
            return ["ok": true]
        case "profile.delete":
            guard let name = payload["name"] as? String else { throw StudioActionError.invalidRequest }
            try model.deleteHarnessProfile(name: name)
            return ["ok": true]
        case "workspace.choose":
            let changed = try await model.chooseWorkspace()
            // The page mirrors the admitted path into its own settings field, so the
            // reply carries the path the app actually launched the Runtime against.
            return [
                "changed": changed,
                "workspacePath": model.settings.workspaceURL.standardizedFileURL.path
            ]
        case "data.open":
            guard model.openDataFolder() else { throw StudioActionError.operationFailed("无法打开数据文件夹") }
            return ["ok": true]
        case "terminal.open":
            guard model.openRuntimeTerminal() else { throw StudioActionError.operationFailed("无法打开 DSH 终端") }
            return ["ok": true]
        case "logs.open":
            guard model.openLogs() else { throw StudioActionError.operationFailed("无法打开日志文件夹") }
            return ["ok": true]
        case "preset.import":
            return ["id": try await model.importAgentPreset() ?? NSNull()] as [String: Any]
        case "preset.export":
            return ["path": try await model.exportAgentPreset()?.path ?? NSNull()] as [String: Any]
        case "runtime.check":
            guard let status = await model.checkRuntimeVersion() else {
                throw StudioActionError.operationFailed("无法获取 Runtime 状态")
            }
            return [
                "kind": status.kind.rawValue,
                "runtimeVersion": status.installed?.runtimeVersion ?? NSNull(),
                "availableVersion": status.available.runtimeVersion,
                "updateAvailable": status.updateAvailable,
                "rollbackAvailable": status.rollbackAvailable
            ]
        case "runtime.update":
            try await model.updateRuntime()
            return ["ok": true]
        case "runtime.rollback":
            try await model.rollbackRuntime()
            return ["ok": true]
        case "diagnostics.copy":
            return ["copied": await model.copyDiagnostics()]
        case "diagnostics.export":
            return ["path": try await model.exportDiagnostics().path]
        case "preference.sync":
            guard let key = payload["key"] as? String,
                  let value = payload["value"],
                  model.applyStudioPreference(key: key, value: value) else {
                throw StudioActionError.invalidRequest
            }
            return ["ok": true]
        default:
            throw StudioActionError.unknownAction
        }
    }

    @MainActor
    private func sendStudioActionReply(
        requestID: String?,
        result: Any? = nil,
        error: String? = nil,
        webView: WKWebView
    ) {
        guard let requestID,
              JSONSerialization.isValidJSONObject(result ?? [:]),
              let resultData = try? JSONSerialization.data(withJSONObject: result ?? [:]),
              let resultJSON = String(data: resultData, encoding: .utf8) else { return }
        let errorJSON = error.map { value -> String in
            let data = try? JSONSerialization.data(withJSONObject: value)
            return String(data: data ?? Data("\"操作失败\"".utf8), encoding: .utf8) ?? "\"操作失败\""
        } ?? "null"
        let script = "window.__dshStudioReceive && window.__dshStudioReceive({requestId:\(jsonString(requestID)),ok:\(error == nil),result:\(resultJSON),error:\(errorJSON)});"
        webView.evaluateJavaScript(script)
    }

    private func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else { return "\"\"" }
        return string
    }

    /// Whether a navigation target is the Runtime this WebView was created for.
    ///
    /// Scheme, host, and port must all match the allowed URL, so a valid loopback URL
    /// for a different local service is rejected.
    ///
    /// - Parameter url: Navigation target to check.
    /// - Returns: `true` when the URL points at the same local Runtime.
    func isAllowed(_ url: URL) -> Bool {
        // Matching host, scheme, and port prevents a valid loopback URL
        // from being used to reach a different local service.
        guard HarnessURLPolicy.isAllowedLoopback(url),
              let allowedURL,
              HarnessURLPolicy.isAllowedLoopback(allowedURL) else {
            return false
        }
        return url.scheme == allowedURL.scheme
            && url.host == allowedURL.host
            && url.port == allowedURL.port
    }
}

private enum StudioActionError: Error, LocalizedError {
    case invalidRequest
    case unknownAction
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "设置操作请求无效"
        case .unknownAction: return "不支持的设置操作"
        case .operationFailed(let message): return message
        }
    }
}
