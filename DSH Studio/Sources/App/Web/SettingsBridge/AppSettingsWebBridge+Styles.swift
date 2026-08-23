//
//  AppSettingsWebBridge+Styles.swift
//  DSH Studio
//

import Foundation

extension AppSettingsWebBridge {
    static let sourcePartOne = #"""
    (() => {
      if (window.__deepseekStudioAppSettingsInstalled) return;

      const handler = window.webkit?.messageHandlers?.deepseekStudio;
      if (!handler) return;
      window.__deepseekStudioAppSettingsInstalled = true;

      // State is supplied by Swift; the page never reads UserDefaults or
      // receives a credential value through this bridge.
      let currentState = {
        workspacePath: "",
        chatContentMaxWidth: 1000,
        dshHomePath: "",
        runtimeError: null,
        harnessVersion: null,
        latestHarnessVersion: null,
        runtimeUpdateAvailable: false,
        turnCompletionNotification: "whenNotFocused",
        permissionNotificationsEnabled: true,
        questionNotificationsEnabled: true,
      };
      let currentNotice = null;
      let block = null;
      let lastRenderedSignature = "";
      let nextRequestID = 0;
      let pending = new Set();
      let lastStateRequestAt = 0;
      let ensureScheduled = false;
      const messages = {
        zh: {
          chatContentWidth: "对话内容宽度",
          chatContentWidthDetail: "限制对话内容区域的最大宽度",
          dataFolder: "数据文件夹",
          openDataFolder: "打开文件夹",
          harnessVersion: "Harness版本",
          latestVersion: "最新版本",
          update: "更新",
          diagnostics: "诊断信息",
          diagnosticsDetail: "用于排查 Runtime、Harness 和数据文件问题",
          copyDiagnostics: "复制诊断信息",
          openLogs: "打开日志文件夹",
          notifications: "通知",
          turnCompletionNotification: "轮次完成通知",
          turnCompletionNotificationDetail: "设置 Harness 完成一轮后何时提醒你",
          turnCompletionNever: "从不",
          turnCompletionAlways: "始终",
          turnCompletionWhenNotFocused: "仅在未聚焦时",
          permissionNotifications: "权限通知",
          permissionNotificationsDetail: "需要你授权后才能继续时提醒你",
          questionNotifications: "问题通知",
          questionNotificationsDetail: "需要你输入后才能继续时提醒你",
          turnCompletionNotificationAria: "轮次完成通知",
          permissionNotificationsAria: "权限通知",
          questionNotificationsAria: "问题通知",
          chatContentWidthAria: "对话内容宽度",
          unknown: "未知",
          notInstalled: "未安装",
        },
        en: {
          chatContentWidth: "Chat content width",
          chatContentWidthDetail: "Limit the maximum width of the chat content area",
          dataFolder: "Data folder",
          openDataFolder: "Open folder",
          harnessVersion: "Harness version",
          latestVersion: "Latest version",
          update: "Update",
          diagnostics: "Diagnostics",
          diagnosticsDetail: "For troubleshooting Runtime, Harness, and data files",
          copyDiagnostics: "Copy diagnostics",
          openLogs: "Open log folder",
          notifications: "Notifications",
          turnCompletionNotification: "Turn completion notification",
          turnCompletionNotificationDetail: "Choose when to be notified after Harness completes a turn",
          turnCompletionNever: "Never",
          turnCompletionAlways: "Always",
          turnCompletionWhenNotFocused: "When not focused",
          permissionNotifications: "Permission notification",
          permissionNotificationsDetail: "Notify when your authorization is needed to continue",
          questionNotifications: "Question notification",
          questionNotificationsDetail: "Notify when your input is needed to continue",
          turnCompletionNotificationAria: "Turn completion notification",
          permissionNotificationsAria: "Permission notification",
          questionNotificationsAria: "Question notification",
          chatContentWidthAria: "Chat content width",
          unknown: "Unknown",
          notInstalled: "Not installed",
        },
      };

      const activeLocale = () => {
        const language = document.documentElement?.lang?.toLowerCase() || "";
        return language.startsWith("zh") ? "zh" : "en";
      };

      const localized = (key, locale = activeLocale()) => messages[locale][key] || key;

      // Every request has an id so a delayed native reply cannot overwrite a
      // newer pending setting change without being rendered as a new state.
      const send = (type, payload = {}) => {
        const requestId = `app-settings-${++nextRequestID}`;
        pending.add(requestId);
        handler.postMessage({ type, requestId, ...payload });
      };

      const receive = (reply) => {
        if (reply.requestId) pending.delete(reply.requestId);
        if (reply.state) currentState = reply.state;
        window.__deepseekStudioSetChatContentMaxWidth?.(currentState.chatContentMaxWidth);
        if (reply.requestId) {
          if (!reply.ok && !reply.cancelled) {
            currentNotice = {
              kind: "error",
              message: reply.error?.message || "设置保存失败",
            };
          } else {
            currentNotice = null;
          }
        }
        scheduleEnsure();
      };

      window.__deepseekStudioReceive = receive;

      const style = document.createElement("style");
      style.dataset.deepseekStudioAppSettingsStyle = "true";
      style.textContent = `
        .dsh-studio-app-settings {
          display: contents;
          color: var(--dsw-alias-label-primary);
        }
        .dsh-studio-app-settings * { box-sizing: border-box; }
        .dsh-studio-app-settings-section-divider {
          width: 100%;
          height: 0;
          flex: none;
          border-bottom: 1px solid var(--dsw-alias-border-l2);
        }
        .dsh-studio-app-settings-row {
          display: flex;
          align-items: center;
          gap: 8px;
          min-width: 0;
          padding: 16px 0;
          border-bottom: 1px solid var(--dsw-alias-border-l2);
        }
        .dsh-studio-app-settings-group-title {
          padding: 20px 0 4px;
          color: var(--dsw-alias-label-secondary);
          font-size: 13px;
          font-weight: 500;
          line-height: 20px;
        }
        .dsh-studio-app-settings-row.last-row {
          border-bottom: none;
        }
        .dsh-studio-app-settings-row-text {
          display: flex;
          flex: 1;
          min-width: 0;
          flex-direction: column;
          gap: 4px;
          padding-right: 48px;
        }
        .dsh-studio-app-settings-title {
          font-size: 14px;
          font-weight: 400;
          line-height: 22px;
          color: var(--dsw-alias-label-primary);
        }
        .dsh-studio-app-settings-detail {
          overflow-wrap: anywhere;
          font-size: 12px;
          font-weight: 400;
          line-height: 18px;
          color: var(--dsw-alias-label-tertiary);
        }
        .dsh-studio-app-settings-value {
          flex: none;
          max-width: 48%;
          overflow-wrap: anywhere;
          font-size: 14px;
          line-height: 22px;
          color: var(--dsw-alias-label-secondary);
          text-align: right;
        }
        .dsh-studio-app-settings-button {
          display: inline-flex;
          flex: none;
          align-items: center;
          justify-content: center;
          height: 36px;
          padding: 0 14px;
          border: none;
          border-radius: 18px;
          background: var(--dsw-alias-bg-module-platform);
          color: var(--dsw-alias-label-primary);
          cursor: pointer;
          font: inherit;
          font-size: 14px;
          line-height: 22px;
          white-space: nowrap;
        }
        .dsh-studio-app-settings-button:hover:not(:disabled) {
          background: var(--dsw-alias-interactive-bg-hover);
        }
        .dsh-studio-app-settings-actions {
          display: flex;
          flex: none;
          flex-wrap: wrap;
          justify-content: flex-end;
          gap: 6px;
        }
        .dsh-studio-app-settings-button:focus-visible,
        .dsh-studio-app-settings-number:focus-visible {
          outline: 1px solid var(--dsw-alias-state-business-primary);
          outline-offset: 1px;
        }
        .dsh-studio-app-settings-button:disabled,
        .dsh-studio-app-settings-number:disabled {
          cursor: default;
          opacity: .6;
        }
        .dsh-studio-app-settings-number {
          box-sizing: border-box;
          width: 96px;
          height: 32px;
          flex: none;
          padding: 0 10px;
          border: 1px solid var(--dsw-alias-border-l2);
          border-radius: 8px;
          background: var(--dsw-alias-bg-layer-1);
          color: var(--dsw-alias-label-primary);
          font: inherit;
          font-size: 14px;
          line-height: 22px;
          text-align: right;
        }
        .dsh-studio-app-settings-number::placeholder {
          color: var(--dsw-alias-label-tertiary);
          opacity: 1;
        }
        .dsh-studio-app-settings-select {
          min-width: 144px;
          height: 32px;
          flex: none;
          padding: 0 8px;
          border: 1px solid var(--dsw-alias-border-l2);
          border-radius: 8px;
          background: var(--dsw-alias-bg-layer-1);
          color: var(--dsw-alias-label-primary);
          font: inherit;
          font-size: 14px;
        }
        .dsh-studio-app-settings-toggle {
          display: inline-flex;
          flex: none;
          align-items: center;
          justify-content: center;
          width: 36px;
          height: 32px;
        }
        .dsh-studio-app-settings-toggle input {
          width: 16px;
          height: 16px;
          margin: 0;
          accent-color: var(--dsw-alias-state-business-primary);
        }
        .dsh-studio-app-settings-version-actions {
          display: flex;
          flex: none;
          align-items: center;
          gap: 8px;
          margin-left: auto;
        }
        .dsh-studio-app-settings-status {
          margin: 8px 0 0;
          font-size: 12px;
          line-height: 18px;
        }
        .dsh-studio-app-settings-status[hidden] { display: none; }
        .dsh-studio-app-settings-status[data-kind="error"] { color: var(--dsw-alias-state-error-primary); }
        @media (max-width: 720px) {
          .dsh-studio-app-settings-row-text { padding-right: 16px; }
          .dsh-studio-app-settings-value { max-width: 42%; }
          .dsh-studio-app-settings-actions { max-width: 50%; }
        }
      `;
      document.head.appendChild(style);

    """#
}
