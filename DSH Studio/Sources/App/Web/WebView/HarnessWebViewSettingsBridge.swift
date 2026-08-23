//
//  HarnessWebViewSettingsBridge.swift
//  DSH Studio
//

import DeepSeekHarness
import DeepSeekLogging
import Foundation
import WebKit

extension HarnessWebView.Coordinator: WKScriptMessageHandler {
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
            case "appSettings.openDataFolder":
                if model.openDataFolder() {
                    sendAppSettingsReply(
                        requestID: requestID,
                        webView: webView
                    )
                } else {
                    sendAppSettingsReply(
                        requestID: requestID,
                        errorCode: "data-folder-open-failed",
                        errorMessage: "无法打开数据文件夹",
                        webView: webView
                    )
                }
            case "appSettings.copyDiagnostics":
                if model.copyDiagnostics() {
                    sendAppSettingsReply(
                        requestID: requestID,
                        message: "诊断信息已复制",
                        webView: webView
                    )
                } else {
                    sendAppSettingsReply(
                        requestID: requestID,
                        errorCode: "diagnostics-copy-failed",
                        errorMessage: "无法复制诊断信息",
                        webView: webView
                    )
                }
            case "appSettings.runtimeUpdate":
                await performRuntimeUpdate(requestID: requestID, webView: webView)
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
        private func performRuntimeUpdate(
            requestID: String?,
            webView: WKWebView
        ) async {
            do {
                try await model.updateRuntime()
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
                guard width.isFinite else {
                    throw AppSettingsBridgeError(
                        code: "invalid-app-setting",
                        message: "对话最大宽度设置值无效"
                    )
                }
                model.settings.chatContentMaxWidth = SettingsStore.normalizedChatContentMaxWidth(width)
            case "turnCompletionNotification":
                guard let rawValue = value as? String,
                      let preference = TurnCompletionNotificationPreference(rawValue: rawValue) else {
                    throw AppSettingsBridgeError(
                        code: "invalid-app-setting",
                        message: "任务完成通知设置值无效"
                    )
                }
                model.settings.turnCompletionNotification = preference
            case "permissionNotificationsEnabled":
                guard let enabled = value as? NSNumber else {
                    throw AppSettingsBridgeError(
                        code: "invalid-app-setting",
                        message: "权限通知设置值无效"
                    )
                }
                model.settings.permissionNotificationsEnabled = enabled.boolValue
            case "questionNotificationsEnabled":
                guard let enabled = value as? NSNumber else {
                    throw AppSettingsBridgeError(
                        code: "invalid-app-setting",
                        message: "问题通知设置值无效"
                    )
                }
                model.settings.questionNotificationsEnabled = enabled.boolValue
            default:
                throw AppSettingsBridgeError(code: "unknown-app-setting", message: "不支持的应用设置：\(key)")
            }
        }

        @MainActor
        func broadcastAppSettingsState() {
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
            return AppSettingsWebState(
                workspacePath: NSString(string: model.settings.workspaceURL.path).abbreviatingWithTildeInPath,
                chatContentMaxWidth: model.settings.chatContentMaxWidth,
                dshHomePath: NSString(string: model.currentDataHomeURL.path).abbreviatingWithTildeInPath,
                runtimeError: currentRuntime.lastError?.uiDescription,
                harnessVersion: currentRuntime.harnessVersion,
                latestHarnessVersion: model.latestSignedHarnessVersion,
                runtimeUpdateAvailable: model.hasVerifiedRuntimeUpdate,
                turnCompletionNotification: model.settings.turnCompletionNotification.rawValue,
                permissionNotificationsEnabled: model.settings.permissionNotificationsEnabled,
                questionNotificationsEnabled: model.settings.questionNotificationsEnabled
            )
        }

        func isAllowed(_ url: URL) -> Bool {
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
