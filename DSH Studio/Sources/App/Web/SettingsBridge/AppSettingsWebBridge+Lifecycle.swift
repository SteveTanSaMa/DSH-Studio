//
//  AppSettingsWebBridge+Lifecycle.swift
//  DSH Studio
//

import Foundation

/// Keeps the injected sections in sync with Harness's own navigation.
extension AppSettingsWebBridge {
    /// The script that re-syncs the injected sections when the page changes.
    static let sourcePartThree = #"""
      // Harness class names are CSS-module generated: "<hash>_<local>". The hash is
      // rebuilt per build, so it must never be hardcoded — it differed between
      // 0.1.5-rc.2 (xmPW5W_options / TKfhPG_section) and 0.1.6-alpha.2
      // (VOzbGW_options / _WvWnq_section), and even between two builds of the same
      // version. The local half is the stable part, and the panel is identified by
      // structure: the navigation element names the module, and the panel is the
      // element that shares its prefix.
      const modulePrefixOf = element => {
        const names = element && element.classList ? Array.from(element.classList) : [];
        const name = names.find(candidate => candidate.indexOf("_") > 0);
        return name ? name.slice(0, name.indexOf("_")) : null;
      };

      const findOptionsByModule = () => {
        const anchors = document.querySelectorAll('[class*="_navList"], [class*="_rail"], [class*="_navTitle"]');
        for (const anchor of anchors) {
          const prefix = modulePrefixOf(anchor);
          if (!prefix) continue;
          const panel = document.querySelector(`.${CSS.escape(prefix)}_options`);
          if (panel) return panel;
        }
        return null;
      };

      // Fallback for a layout that exposes no navigation anchor: accept only a
      // candidate that actually contains a section, so another package's
      // "*_options" element cannot be mistaken for the Settings panel.
      const findOptionsByShape = () => {
        const candidates = Array.from(document.querySelectorAll('[class*="_options"]'));
        return candidates.find(candidate => candidate.querySelector('[class*="_section"]')) || null;
      };

      const findOptions = () => findOptionsByModule() || findOptionsByShape();

      // Any element whose class ends in "_section" inside the located panel is the
      // active settings section; Harness renders one at a time.
      const findGeneral = options => options?.querySelector('[class*="_section"]') || null;

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
        if (general) {
          attachGeneralBlock(general);
        } else if (!anchorWarningSent) {
          // Staying silent would make a Harness layout change look like the
          // settings simply vanished, so report it once for the native log.
          anchorWarningSent = true;
          if (window.console && window.console.warn) {
            window.console.warn("DSH Studio: app settings anchor not found; injected section was not attached.");
          }
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
