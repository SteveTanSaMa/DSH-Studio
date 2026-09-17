//
//  AppSettingsWebBridge+Behavior.swift
//  DSH Studio
//

import Foundation

/// The behavior half of the injected settings sections.
///
/// Installs the DOM, requests state from Swift, and posts user edits back.
extension AppSettingsWebBridge {
    /// The script that requests state and posts user edits back to Swift.
    static let sourcePartTwo = #"""
      const text = (root, selector, value, fallback = "未知") => {
        const element = root.querySelector(selector);
        if (element) element.textContent = value ?? fallback;
      };

      const bindInteractions = element => {
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
          if (!input) return;
          input.dataset.editing = "true";
          delete input.dataset.empty;
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
          const option = event.target.closest?.("[data-app-option]");
          const selectTrigger = event.target.closest?.('[data-app-key="turnCompletionNotification"]');
          const switchControl = event.target.closest?.('[role="switch"]');
          const button = event.target.closest?.("[data-app-action]");
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
          if (button.dataset.appAction === "openDataFolder") send("appSettings.openDataFolder");
          if (button.dataset.appAction === "chooseWorkspace") send("appSettings.chooseWorkspace");
          scheduleEnsure();
        });
      };

      const createGeneralBlock = () => {
        const element = document.createElement("div");
        element.className = "dsh-studio-app-settings dsh-studio-app-settings-general";
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
              <div class="dsh-studio-app-settings-title" data-app-i18n="workspace">工作区</div>
              <div class="dsh-studio-app-settings-detail" data-app-field="workspace"></div>
            </div>
            <button type="button" class="dsh-studio-app-settings-button" data-app-action="chooseWorkspace" data-app-i18n="chooseWorkspace">选择工作区</button>
          </div>
          <div class="dsh-studio-app-settings-row">
            <div class="dsh-studio-app-settings-row-text">
              <div class="dsh-studio-app-settings-title" data-app-i18n="dataFolder">数据文件夹</div>
              <div class="dsh-studio-app-settings-detail" data-app-field="dsh-home"></div>
            </div>
            <button type="button" class="dsh-studio-app-settings-button" data-app-action="openDataFolder" data-app-i18n="openDataFolder">打开文件夹</button>
          </div>
          <div class="dsh-studio-app-settings-group-title" data-app-i18n="notifications">通知</div>
          <div class="dsh-studio-app-settings-row dsh-studio-app-settings-notification-row">
            <div class="dsh-studio-app-settings-row-text">
              <div class="dsh-studio-app-settings-title" data-app-i18n="turnCompletionNotification">轮次完成通知</div>
              <div class="dsh-studio-app-settings-detail" data-app-i18n="turnCompletionNotificationDetail">设置 DSH Studio 完成后何时提醒您</div>
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
          <div class="dsh-studio-app-settings-status" aria-live="polite" data-app-field="status" hidden></div>
        `;
        bindInteractions(element);
        return element;
      };

      // Rendering is signature-based so MutationObserver callbacks do not
      // reset the width field while the user is typing.
      const render = () => {
        if (!generalBlock) return;
        const locale = activeLocale();
        const signature = JSON.stringify({ state: currentState, notice: currentNotice, pending: pending.size, locale });
        if (signature === lastRenderedSignature) return;
        lastRenderedSignature = signature;
        const busy = pending.size > 0;
        generalBlock.querySelectorAll("[data-app-i18n]").forEach(element => {
          element.textContent = localized(element.dataset.appI18n, locale);
        });
        generalBlock.querySelectorAll("[data-app-i18n-aria-label]").forEach(element => {
          element.setAttribute("aria-label", localized(element.dataset.appI18nAriaLabel, locale));
        });
        text(generalBlock, '[data-app-field="workspace"]', currentState.workspacePath, localized("unknown", locale));
        text(generalBlock, '[data-app-field="dsh-home"]', currentState.dshHomePath, localized("unknown", locale));

        const chatWidth = generalBlock.querySelector('input[data-app-key="chatContentMaxWidth"]');
        if (chatWidth && !chatWidth.dataset.editing) {
          chatWidth.value = chatWidth.dataset.empty ? "" : String(currentState.chatContentMaxWidth ?? 1000);
          chatWidth.disabled = busy;
        }
        const completionValue = currentState.turnCompletionNotification || "whenNotFocused";
        const completion = generalBlock.querySelector('[data-app-key="turnCompletionNotification"]');
        if (completion) {
          completion.disabled = busy;
          completion.setAttribute("aria-expanded", busy ? "false" : completion.getAttribute("aria-expanded") || "false");
        }
        const completionLabel = generalBlock.querySelector('[data-app-field="turnCompletionNotificationValue"]');
        const selectedOption = generalBlock.querySelector(`[data-app-option="${completionValue}"]`);
        if (completionLabel) {
          completionLabel.textContent = selectedOption
            ? localized(selectedOption.dataset.appI18n, locale)
            : localized("turnCompletionWhenNotFocused", locale);
        }
        const completionMenu = generalBlock.querySelector('[data-app-field="turnCompletionNotificationMenu"]');
        if (completionMenu) {
          if (busy) completionMenu.hidden = true;
          completionMenu.querySelectorAll("[data-app-option]").forEach(option => {
            option.disabled = busy;
            option.setAttribute("aria-selected", String(option.dataset.appOption === completionValue));
          });
        }
        ["permissionNotificationsEnabled", "questionNotificationsEnabled"].forEach(key => {
          const control = generalBlock.querySelector(`[data-app-key="${key}"]`);
          if (!control) return;
          control.setAttribute("aria-checked", String(currentState[key] !== false));
          control.disabled = busy;
        });
        generalBlock.querySelectorAll("[data-app-action]").forEach(button => { button.disabled = busy; });
        const status = generalBlock.querySelector('[data-app-field="status"]');
        if (status) {
          const message = currentNotice?.kind === "error" ? currentNotice.message : "";
          status.hidden = !message;
          status.textContent = message;
          status.dataset.kind = currentNotice?.kind || "info";
        }
      };

    """#
}
