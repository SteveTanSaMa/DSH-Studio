//
//  AppSettingsWebBridge.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import Foundation

/// DOM bridge for the App-owned settings section injected into Harness's
/// official Settings > General surface. Harness settings remain in the
/// official Web UI and continue to use the loopback `settings.*` API.
enum AppSettingsWebBridge {
    static let messageHandlerName = "deepseekStudio"

    static let source = #"""
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

      const text = (root, selector, value, fallback = "未知") => {
        const element = root.querySelector(selector);
        if (element) element.textContent = value ?? fallback;
      };

      // Harness owns the settings page. This block is inserted into its General
      // section and removed whenever that section is unmounted or replaced.
      const createBlock = () => {
        const element = document.createElement("div");
        element.className = "dsh-studio-app-settings";
        element.dataset.deepseekStudioAppSettings = "true";
        element.dataset.slot = "settings.general.item";
        element.innerHTML = `
          <div class="dsh-studio-app-settings-section-divider" aria-hidden="true"></div>
          <div class="dsh-studio-app-settings-row">
            <div class="dsh-studio-app-settings-row-text">
              <div class="dsh-studio-app-settings-title" data-app-i18n="chatContentWidth">对话内容宽度</div>
              <div class="dsh-studio-app-settings-detail" data-app-i18n="chatContentWidthDetail">限制对话内容区域的最大宽度</div>
            </div>
            <input class="dsh-studio-app-settings-number" type="text" inputmode="numeric" placeholder="748–2400" data-app-key="chatContentMaxWidth" data-app-i18n-aria-label="chatContentWidthAria" aria-label="对话内容宽度" />
          </div>
          <div class="dsh-studio-app-settings-row">
            <div class="dsh-studio-app-settings-row-text">
              <div class="dsh-studio-app-settings-title" data-app-i18n="dataFolder">数据文件夹</div>
              <div class="dsh-studio-app-settings-detail" data-app-field="dsh-home"></div>
            </div>
            <button type="button" class="dsh-studio-app-settings-button" data-app-action="openDataFolder" data-app-i18n="openDataFolder">打开文件夹</button>
          </div>
          <div class="dsh-studio-app-settings-row">
            <div class="dsh-studio-app-settings-row-text">
              <div class="dsh-studio-app-settings-title" data-app-i18n="harnessVersion">Harness版本</div>
              <div class="dsh-studio-app-settings-detail"><span data-app-i18n="latestVersion">最新版本</span> <span data-app-field="latest-harness-version"></span></div>
            </div>
            <div class="dsh-studio-app-settings-version-actions">
              <button type="button" class="dsh-studio-app-settings-button" data-app-action="runtimeUpdate" data-app-i18n="update" hidden>更新</button>
              <span class="dsh-studio-app-settings-value" data-app-field="harness-version"></span>
            </div>
          </div>
          <div class="dsh-studio-app-settings-row last-row">
            <div class="dsh-studio-app-settings-row-text">
              <div class="dsh-studio-app-settings-title" data-app-i18n="diagnostics">诊断信息</div>
              <div class="dsh-studio-app-settings-detail" data-app-i18n="diagnosticsDetail">用于排查 Runtime、Harness 和数据文件问题</div>
            </div>
            <div class="dsh-studio-app-settings-actions">
              <button type="button" class="dsh-studio-app-settings-button" data-app-action="copyDiagnostics" data-app-i18n="copyDiagnostics">复制诊断信息</button>
              <button type="button" class="dsh-studio-app-settings-button" data-app-action="logs" data-app-i18n="openLogs">打开日志文件夹</button>
            </div>
          </div>
          <div class="dsh-studio-app-settings-status" aria-live="polite" data-app-field="status" hidden></div>
        `;
          const commitWidth = input => {
            const raw = input.value.trim();
            if (!raw) {
              input.value = "";
              input.dataset.empty = "true";
              return;
            }
            const number = Number(raw);
            if (!Number.isFinite(number)) {
              input.value = String(currentState.chatContentMaxWidth ?? 1000);
              return;
            }
            const value = Math.min(Math.max(number, 748), 2400);
            input.value = String(value);
            send("appSettings.update", { key: "chatContentMaxWidth", value });
            scheduleEnsure();
          };
          element.addEventListener("focusin", event => {
            const input = event.target.closest?.('input[data-app-key="chatContentMaxWidth"]');
            if (input) {
              input.dataset.editing = "true";
              delete input.dataset.empty;
            }
          });
          element.addEventListener("focusout", event => {
            const input = event.target.closest?.('input[data-app-key="chatContentMaxWidth"]');
            if (!input) return;
            delete input.dataset.editing;
            commitWidth(input);
          });
          element.addEventListener("keydown", event => {
            const input = event.target.closest?.('input[data-app-key="chatContentMaxWidth"]');
            if (input && event.key === "Enter") {
              event.preventDefault();
              input.blur();
            }
          });
        element.addEventListener("click", event => {
          const button = event.target.closest?.("[data-app-action]");
          if (!button || button.disabled) return;
          const action = button.dataset.appAction;
          if (action === "openDataFolder") send("appSettings.openDataFolder");
          if (action === "logs") send("appSettings.openLogs");
          if (action === "copyDiagnostics") send("appSettings.copyDiagnostics");
          if (action === "runtimeUpdate") send("appSettings.runtimeUpdate");
          scheduleEnsure();
        });
        return element;
      };

      // Rendering is signature-based to avoid resetting the number field on
      // every MutationObserver callback while the user is typing.
      const render = () => {
        if (!block) return;
        const locale = activeLocale();
        const signature = JSON.stringify({ state: currentState, notice: currentNotice, pending: pending.size, locale });
        if (signature === lastRenderedSignature) return;
        lastRenderedSignature = signature;
        const busy = pending.size > 0;
        block.querySelectorAll("[data-app-i18n]").forEach(element => {
          element.textContent = localized(element.dataset.appI18n, locale);
        });
        block.querySelectorAll("[data-app-i18n-aria-label]").forEach(element => {
          element.setAttribute("aria-label", localized(element.dataset.appI18nAriaLabel, locale));
        });
        text(block, '[data-app-field="workspace"]', currentState.workspacePath, localized("unknown", locale));
        text(block, '[data-app-field="harness-version"]', currentState.harnessVersion || localized("notInstalled", locale));
        text(block, '[data-app-field="latest-harness-version"]', currentState.latestHarnessVersion, localized("unknown", locale));
        text(block, '[data-app-field="dsh-home"]', currentState.dshHomePath, localized("unknown", locale));
        const chatWidth = block.querySelector('input[data-app-key="chatContentMaxWidth"]');
        if (chatWidth && !chatWidth.dataset.editing) {
          chatWidth.value = chatWidth.dataset.empty
            ? ""
            : String(currentState.chatContentMaxWidth ?? 1000);
          chatWidth.disabled = busy;
        }
        block.querySelectorAll("[data-app-action]").forEach(button => { button.disabled = busy; });
        const updateButton = block.querySelector('[data-app-action="runtimeUpdate"]');
        if (updateButton) updateButton.disabled = busy || !currentState.runtimeUpdateAvailable;
        if (updateButton) updateButton.hidden = !currentState.runtimeUpdateAvailable;
        const status = block.querySelector('[data-app-field="status"]');
        if (status) {
          const notice = currentNotice || (currentState.runtimeError ? { kind: "error", message: currentState.runtimeError } : null);
          const message = notice?.kind === "error" ? notice.message : "";
          status.hidden = !message;
          status.textContent = message;
          status.dataset.kind = notice?.kind || "info";
        }
      };

      const findOptions = () => document.querySelector(".VOzbGW_options") || document.querySelector('[class*="_options"]');

      const removeBlocks = () => {
        document.querySelectorAll(".dsh-studio-app-settings").forEach(element => element.remove());
        block = null;
        lastRenderedSignature = "";
      };

      // Harness can recreate the Settings DOM after navigation or tab changes;
      // this reconciler puts the App-owned rows back when necessary.
      const ensure = () => {
        const options = findOptions();
        const general = options?.querySelector("._WvWnq_section") || options?.querySelector('[class*="_WvWnq_section"]');
        if (!general) {
          removeBlocks();
          return;
        }
        const existing = general.querySelector("[data-deepseek-studio-app-settings]");
        if (existing) {
          block = existing;
        } else {
          removeBlocks();
          block = createBlock();
          general.appendChild(block);
        }
        render();
        if (Date.now() - lastStateRequestAt > 30000 && pending.size === 0) {
          lastStateRequestAt = Date.now();
          send("appSettings.request");
        }
      };

      const scheduleEnsure = () => {
        if (ensureScheduled) return;
        ensureScheduled = true;
        window.requestAnimationFrame(() => {
          ensureScheduled = false;
          ensure();
        });
      };

      document.addEventListener("click", scheduleEnsure, true);
      const observer = new MutationObserver(scheduleEnsure);
      observer.observe(document.documentElement, {
        attributes: true,
        attributeFilter: ["lang"],
        childList: true,
        subtree: true,
      });
      send("appSettings.request");
      scheduleEnsure();
    })();
    """#
}

/// Serializable snapshot returned to the injected App settings section.
struct AppSettingsWebState: Codable, Equatable, Sendable {
    let workspacePath: String
    let chatContentMaxWidth: Double
    let dshHomePath: String
    let runtimeError: String?
    let harnessVersion: String?
    let latestHarnessVersion: String?
    let runtimeUpdateAvailable: Bool
}
