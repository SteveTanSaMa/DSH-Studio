//
//  AppSettingsWebBridge+Lifecycle.swift
//  DSH Studio
//

import Foundation

extension AppSettingsWebBridge {
    static let sourcePartThree = #"""
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

      document.addEventListener("click", event => {
        const menu = document.querySelector('[data-app-field="turnCompletionNotificationMenu"]');
        const trigger = document.querySelector('[data-app-key="turnCompletionNotification"]');
        if (menu && trigger && !menu.contains(event.target) && !trigger.contains(event.target)) {
          menu.hidden = true;
          trigger.setAttribute("aria-expanded", "false");
        }
        scheduleEnsure();
      }, true);
      document.addEventListener("keydown", event => {
        if (event.key !== "Escape") return;
        const menu = document.querySelector('[data-app-field="turnCompletionNotificationMenu"]');
        const trigger = document.querySelector('[data-app-key="turnCompletionNotification"]');
        if (!menu || menu.hidden) return;
        menu.hidden = true;
        trigger?.setAttribute("aria-expanded", "false");
        trigger?.focus();
      });
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
