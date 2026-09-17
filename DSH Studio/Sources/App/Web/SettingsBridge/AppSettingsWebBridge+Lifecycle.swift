//
//  AppSettingsWebBridge+Lifecycle.swift
//  DSH Studio
//

import Foundation

/// Keeps the injected sections in sync with Harness's own navigation.
extension AppSettingsWebBridge {
    /// The script that re-syncs the injected sections when the page changes.
    static let sourcePartThree = #"""
      const findOptions = () => document.querySelector(".VOzbGW_options") || document.querySelector('[class*="_options"]');
      const findGeneral = options => options?.querySelector("._WvWnq_section") || options?.querySelector('[class*="_WvWnq_section"]');

      const attachGeneralBlock = general => {
        if (!generalBlock) generalBlock = createGeneralBlock();
        if (generalBlock.parentElement !== general) general.appendChild(generalBlock);
      };

      // Harness can recreate the Settings DOM after navigation or tab changes.
      // Reconcile only the General contribution and leave native navigation
      // and plugin-market entries entirely under Harness's control.
      const ensure = () => {
        const options = findOptions();
        const general = findGeneral(options);
        if (general) attachGeneralBlock(general);
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
      const observer = new MutationObserver(mutations => {
        if (mutations.some(mutation => mutation.type === "childList" || mutation.attributeName === "lang" || mutation.attributeName === "class")) {
          scheduleEnsure();
        }
      });
      observer.observe(document.documentElement, {
        attributes: true,
        attributeFilter: ["lang", "class"],
        childList: true,
        subtree: true,
      });
      send("appSettings.request");
      scheduleEnsure();
    })();
    """#
}
