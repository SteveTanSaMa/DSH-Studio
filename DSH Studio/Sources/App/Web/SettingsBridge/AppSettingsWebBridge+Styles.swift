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
      // receives credentials through this bridge.
      let currentState = {
        workspacePath: "",
        chatContentMaxWidth: 1000,
        dshHomePath: "",
        turnCompletionNotification: "whenNotFocused",
        permissionNotificationsEnabled: true,
        questionNotificationsEnabled: true,
      };
      let currentNotice = null;
      let generalBlock = null;
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
          workspace: "工作区",
          chooseWorkspace: "选择工作区",
          notifications: "通知",
          turnCompletionNotification: "轮次完成通知",
          turnCompletionNotificationDetail: "设置 DSH Studio 完成后何时提醒您",
          turnCompletionNever: "从不",
          turnCompletionAlways: "始终",
          turnCompletionWhenNotFocused: "仅在未聚焦时",
          permissionNotifications: "启用权限通知",
          permissionNotificationsDetail: "在需要通知权限时显示提醒",
          questionNotifications: "启用问题通知",
          questionNotificationsDetail: "需要输入才能继续时显示提醒",
          turnCompletionNotificationAria: "轮次完成通知",
          permissionNotificationsAria: "启用权限通知",
          questionNotificationsAria: "启用问题通知",
          chatContentWidthAria: "对话内容宽度",
          unknown: "未知",
        },
        en: {
          chatContentWidth: "Chat content width",
          chatContentWidthDetail: "Limit the maximum width of the chat content area",
          dataFolder: "Data folder",
          openDataFolder: "Open folder",
          workspace: "Workspace",
          chooseWorkspace: "Choose workspace",
          notifications: "Notifications",
          turnCompletionNotification: "Turn completion notification",
          turnCompletionNotificationDetail: "Choose when to be notified after DSH Studio finishes",
          turnCompletionNever: "Never",
          turnCompletionAlways: "Always",
          turnCompletionWhenNotFocused: "When not focused",
          permissionNotifications: "Enable permission notifications",
          permissionNotificationsDetail: "Show a reminder when notification permission is needed",
          questionNotifications: "Enable question notifications",
          questionNotificationsDetail: "Show a reminder when input is needed to continue",
          turnCompletionNotificationAria: "Turn completion notification",
          permissionNotificationsAria: "Enable permission notifications",
          questionNotificationsAria: "Enable question notifications",
          chatContentWidthAria: "Chat content width",
          unknown: "Unknown",
        },
      };

      const activeLocale = () => {
        const language = document.documentElement?.lang?.toLowerCase() || "";
        return language.startsWith("zh") ? "zh" : "en";
      };

      const localized = (key, locale = activeLocale()) => messages[locale][key] || key;

      const send = (type, payload = {}) => {
        const requestId = `app-settings-${++nextRequestID}`;
        pending.add(requestId);
        handler.postMessage({ type, requestId, ...payload });
      };

      const receive = reply => {
        if (reply.requestId) pending.delete(reply.requestId);
        if (reply.state) currentState = reply.state;
        window.__deepseekStudioSetChatContentMaxWidth?.(currentState.chatContentMaxWidth);
        if (reply.requestId) {
          currentNotice = !reply.ok && !reply.cancelled
            ? { kind: "error", message: reply.error?.message || "设置保存失败" }
            : null;
        }
        scheduleEnsure();
      };

      window.__deepseekStudioReceive = receive;

      const style = document.createElement("style");
      style.dataset.deepseekStudioAppSettingsStyle = "true";
      style.textContent = `
    """# + appSettingsCSS + #"""
      `;
      document.head.appendChild(style);
    """#
}
