//
//  AppSettingsWebBridge.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
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
        chatContentMaxWidth: 1200,
        dshHomePath: "",
        runtimeState: "正在读取",
        runtimeAvailable: false,
        runtimeError: null,
        harnessVersion: null,
        nodeVersion: null,
      };
      let currentNotice = null;
      let block = null;
      let lastRenderedSignature = "";
      let nextRequestID = 0;
      let pending = new Set();
      let lastStateRequestAt = 0;
      let ensureScheduled = false;

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
        .dsh-studio-app-settings-divider {
          width: 100%;
          height: 1px;
          flex: none;
          background: var(--dsw-alias-border-l2);
        }
        .dsh-studio-app-settings-row {
          display: flex;
          align-items: center;
          gap: 8px;
          min-width: 0;
          padding: 16px 0;
          border-bottom: 1px solid var(--dsw-alias-border-l2);
        }
        .dsh-studio-app-settings-row.last-row { border-bottom: none; }
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
        .dsh-studio-app-settings-status {
          margin: 8px 0 0;
          font-size: 12px;
          line-height: 18px;
        }
        .dsh-studio-app-settings-status[hidden] { display: none; }
        .dsh-studio-app-settings-status[data-kind="error"] { color: var(--dsw-alias-state-error-primary); }
        .dsh-studio-app-settings-runtime-error { color: var(--dsw-alias-state-error-primary); }
        @media (max-width: 720px) {
          .dsh-studio-app-settings-row-text { padding-right: 16px; }
          .dsh-studio-app-settings-value { max-width: 42%; }
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
          <div class="dsh-studio-app-settings-divider" aria-hidden="true"></div>
          <div class="dsh-studio-app-settings-row">
            <div class="dsh-studio-app-settings-row-text">
              <div class="dsh-studio-app-settings-title">当前工作区</div>
              <div class="dsh-studio-app-settings-detail" data-app-field="workspace"></div>
            </div>
            <button type="button" class="dsh-studio-app-settings-button" data-app-action="workspace">选择目录</button>
          </div>
          <div class="dsh-studio-app-settings-row">
            <div class="dsh-studio-app-settings-row-text">
              <div class="dsh-studio-app-settings-title">Harness 数据目录</div>
              <div class="dsh-studio-app-settings-detail" data-app-field="dsh-home"></div>
            </div>
            <button type="button" class="dsh-studio-app-settings-button" data-app-action="dshHome">选择目录</button>
          </div>
          <div class="dsh-studio-app-settings-row">
            <div class="dsh-studio-app-settings-row-text">
              <div class="dsh-studio-app-settings-title">对话内容宽度</div>
              <div class="dsh-studio-app-settings-detail">限制对话内容区域的最大宽度（像素）</div>
            </div>
            <input class="dsh-studio-app-settings-number" type="number" min="748" max="2400" step="16" data-app-key="chatContentMaxWidth" aria-label="对话内容宽度" />
          </div>
          <div class="dsh-studio-app-settings-row">
            <div class="dsh-studio-app-settings-row-text">
              <div class="dsh-studio-app-settings-title">Runtime 状态</div>
              <div class="dsh-studio-app-settings-detail" data-app-field="runtime-error"></div>
            </div>
            <span class="dsh-studio-app-settings-value" data-app-field="runtime-state"></span>
          </div>
          <div class="dsh-studio-app-settings-row">
            <div class="dsh-studio-app-settings-row-text">
              <div class="dsh-studio-app-settings-title">Harness 版本</div>
              <div class="dsh-studio-app-settings-detail">当前使用的 Harness 版本</div>
            </div>
            <span class="dsh-studio-app-settings-value" data-app-field="harness-version"></span>
          </div>
          <div class="dsh-studio-app-settings-row">
            <div class="dsh-studio-app-settings-row-text">
              <div class="dsh-studio-app-settings-title">Node 版本</div>
              <div class="dsh-studio-app-settings-detail">当前使用的 Node.js 版本</div>
            </div>
            <span class="dsh-studio-app-settings-value" data-app-field="node-version"></span>
          </div>
          <div class="dsh-studio-app-settings-row last-row">
            <div class="dsh-studio-app-settings-row-text">
              <div class="dsh-studio-app-settings-title">运行日志</div>
              <div class="dsh-studio-app-settings-detail">查看 Runtime 状态、错误和最近运行记录</div>
            </div>
            <button type="button" class="dsh-studio-app-settings-button" data-app-action="logs">查看日志</button>
          </div>
          <div class="dsh-studio-app-settings-status" aria-live="polite" data-app-field="status" hidden></div>
        `;
        element.addEventListener("change", event => {
          const input = event.target.closest?.("[data-app-key]");
          if (!input || input.disabled) return;
          const key = input.dataset.appKey;
          const value = input.type === "checkbox" ? input.checked : Number(input.value);
          if (!key || (input.type !== "checkbox" && !Number.isFinite(value))) return;
          send("appSettings.update", { key, value });
          scheduleEnsure();
        });
        element.addEventListener("click", event => {
          const button = event.target.closest?.("[data-app-action]");
          if (!button || button.disabled) return;
          const action = button.dataset.appAction;
          if (action === "workspace") send("appSettings.chooseWorkspace");
          if (action === "dshHome") send("appSettings.chooseDSHHome");
          if (action === "logs") send("appSettings.openLogs");
          scheduleEnsure();
        });
        return element;
      };

      // Rendering is signature-based to avoid resetting the number field on
      // every MutationObserver callback while the user is typing.
      const render = () => {
        if (!block) return;
        const signature = JSON.stringify({ state: currentState, notice: currentNotice, pending: pending.size });
        if (signature === lastRenderedSignature) return;
        lastRenderedSignature = signature;
        const busy = pending.size > 0;
        text(block, '[data-app-field="workspace"]', currentState.workspacePath);
        text(block, '[data-app-field="runtime-state"]', currentState.runtimeState || "未知");
        text(block, '[data-app-field="runtime-error"]', currentState.runtimeError, "当前 Harness Runtime 状态");
        text(block, '[data-app-field="harness-version"]', currentState.harnessVersion || "未知");
        text(block, '[data-app-field="node-version"]', currentState.nodeVersion || "未知");
        text(block, '[data-app-field="dsh-home"]', currentState.dshHomePath);
        const runtimeState = block.querySelector('[data-app-field="runtime-state"]');
        if (runtimeState) runtimeState.classList.toggle("dsh-studio-app-settings-runtime-error", !currentState.runtimeAvailable && !!currentState.runtimeError);
        const runtimeError = block.querySelector('[data-app-field="runtime-error"]');
        if (runtimeError) runtimeError.classList.toggle("dsh-studio-app-settings-runtime-error", !!currentState.runtimeError);
        const chatWidth = block.querySelector('input[data-app-key="chatContentMaxWidth"]');
        if (chatWidth) {
          chatWidth.value = String(currentState.chatContentMaxWidth ?? 1200);
          chatWidth.disabled = busy;
        }
        block.querySelectorAll("[data-app-action]").forEach(button => { button.disabled = busy; });
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
        if (Date.now() - lastStateRequestAt > 2000 && pending.size === 0) {
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
      observer.observe(document.documentElement, { childList: true, subtree: true });
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
    let runtimeState: String
    let runtimeAvailable: Bool
    let runtimeError: String?
    let harnessVersion: String?
    let nodeVersion: String?
}
