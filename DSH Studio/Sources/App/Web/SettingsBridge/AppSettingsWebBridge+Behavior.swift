//
//  AppSettingsWebBridge+Behavior.swift
//  DSH Studio
//

import Foundation

extension AppSettingsWebBridge {
    static let sourcePartTwo = #"""
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
          <div class="dsh-studio-app-settings-group-title" data-app-i18n="notifications">通知</div>
          <div class="dsh-studio-app-settings-row dsh-studio-app-settings-notification-row">
            <div class="dsh-studio-app-settings-row-text">
              <div class="dsh-studio-app-settings-title" data-app-i18n="turnCompletionNotification">轮次完成通知</div>
              <div class="dsh-studio-app-settings-detail" data-app-i18n="turnCompletionNotificationDetail">设置 ChatGPT 完成后何时提醒您</div>
            </div>
            <div class="dsh-studio-app-settings-select-wrap">
              <button type="button" class="dsh-studio-app-settings-select-trigger" data-app-key="turnCompletionNotification" data-app-i18n-aria-label="turnCompletionNotificationAria" aria-label="轮次完成通知" aria-haspopup="listbox" aria-expanded="false">
                <span data-app-field="turnCompletionNotificationValue"></span>
                <span class="dsh-studio-app-settings-select-chevron" aria-hidden="true"></span>
              </button>
              <div class="dsh-studio-app-settings-select-menu" data-app-field="turnCompletionNotificationMenu" role="listbox" hidden>
                <button type="button" class="dsh-studio-app-settings-select-option" data-app-option="never" data-app-i18n="turnCompletionNever" role="option">从不</button>
                <button type="button" class="dsh-studio-app-settings-select-option" data-app-option="always" data-app-i18n="turnCompletionAlways" role="option">始终</button>
                <button type="button" class="dsh-studio-app-settings-select-option" data-app-option="whenNotFocused" data-app-i18n="turnCompletionWhenNotFocused" role="option">仅在未聚焦时</button>
              </div>
            </div>
          </div>
          <div class="dsh-studio-app-settings-row dsh-studio-app-settings-notification-row">
            <div class="dsh-studio-app-settings-row-text">
              <div class="dsh-studio-app-settings-title" data-app-i18n="permissionNotifications">启用权限通知</div>
              <div class="dsh-studio-app-settings-detail" data-app-i18n="permissionNotificationsDetail">在需要通知权限时显示提醒</div>
            </div>
            <button type="button" class="dsh-studio-app-settings-switch" data-app-key="permissionNotificationsEnabled" data-app-i18n-aria-label="permissionNotificationsAria" aria-label="启用权限通知" role="switch" aria-checked="true">
              <span class="dsh-studio-app-settings-switch-track"><span class="dsh-studio-app-settings-switch-thumb"></span></span>
            </button>
          </div>
          <div class="dsh-studio-app-settings-row dsh-studio-app-settings-notification-row dsh-studio-app-settings-notification-row-last">
            <div class="dsh-studio-app-settings-row-text">
              <div class="dsh-studio-app-settings-title" data-app-i18n="questionNotifications">启用问题通知</div>
              <div class="dsh-studio-app-settings-detail" data-app-i18n="questionNotificationsDetail">需要输入才能继续时显示提醒</div>
            </div>
            <button type="button" class="dsh-studio-app-settings-switch" data-app-key="questionNotificationsEnabled" data-app-i18n-aria-label="questionNotificationsAria" aria-label="启用问题通知" role="switch" aria-checked="true">
              <span class="dsh-studio-app-settings-switch-track"><span class="dsh-studio-app-settings-switch-thumb"></span></span>
            </button>
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
          const option = event.target.closest?.("[data-app-option]");
          const selectTrigger = event.target.closest?.('[data-app-key="turnCompletionNotification"]');
          const switchControl = event.target.closest?.('[role="switch"]');
          if (option && !option.disabled) {
            const menu = option.closest('[data-app-field="turnCompletionNotificationMenu"]');
            const trigger = element.querySelector('[data-app-key="turnCompletionNotification"]');
            send("appSettings.update", { key: "turnCompletionNotification", value: option.dataset.appOption });
            if (menu) menu.hidden = true;
            if (trigger) trigger.setAttribute("aria-expanded", "false");
            scheduleEnsure();
            return;
          }
          if (selectTrigger && !selectTrigger.disabled) {
            const menu = element.querySelector('[data-app-field="turnCompletionNotificationMenu"]');
            const expanded = selectTrigger.getAttribute("aria-expanded") === "true";
            if (menu) menu.hidden = expanded;
            selectTrigger.setAttribute("aria-expanded", String(!expanded));
            return;
          }
          if (switchControl && !switchControl.disabled) {
            const value = switchControl.getAttribute("aria-checked") !== "true";
            switchControl.setAttribute("aria-checked", String(value));
            send("appSettings.update", { key: switchControl.dataset.appKey, value });
            scheduleEnsure();
            return;
          }
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
        const completionValue = currentState.turnCompletionNotification || "whenNotFocused";
        const completion = block.querySelector('[data-app-key="turnCompletionNotification"]');
        if (completion) {
          completion.disabled = busy;
          completion.setAttribute("aria-expanded", busy ? "false" : completion.getAttribute("aria-expanded") || "false");
        }
        const completionLabel = block.querySelector('[data-app-field="turnCompletionNotificationValue"]');
        if (completionLabel) {
          const option = block.querySelector(`[data-app-option="${completionValue}"]`);
          completionLabel.textContent = option ? localized(option.dataset.appI18n, locale) : localized("turnCompletionWhenNotFocused", locale);
        }
        const completionMenu = block.querySelector('[data-app-field="turnCompletionNotificationMenu"]');
        if (completionMenu) {
          if (busy) completionMenu.hidden = true;
          completionMenu.querySelectorAll("[data-app-option]").forEach(option => {
            option.disabled = busy;
            option.setAttribute("aria-selected", String(option.dataset.appOption === completionValue));
          });
        }
        const permission = block.querySelector('[data-app-key="permissionNotificationsEnabled"]');
        if (permission) {
          permission.setAttribute("aria-checked", String(currentState.permissionNotificationsEnabled !== false));
          permission.disabled = busy;
        }
        const question = block.querySelector('[data-app-key="questionNotificationsEnabled"]');
        if (question) {
          question.setAttribute("aria-checked", String(currentState.questionNotificationsEnabled !== false));
          question.disabled = busy;
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

    """#
}
