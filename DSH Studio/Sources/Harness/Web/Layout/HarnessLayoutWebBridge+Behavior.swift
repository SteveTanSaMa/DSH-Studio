//
//  HarnessLayoutWebBridge+Behavior.swift
//  DSH Studio
//

import Foundation

/// The behavior half of the presentation-only layout adjustments.
///
/// Aligns the hero, mirrors the sidebar's collapsed state, and isolates the
/// input scrollport from Harness's edge-wheel forwarding behavior.
extension HarnessLayoutWebBridge {
    /// The script that aligns the hero and mirrors the sidebar state.
    static let sourcePartTwo = #"""
      let heroAlignmentFrame = 0;
      let sidebarStateFrame = 0;
      let heroStructureDirty = true;
      let heroEntries = [];
      let observedHeroElements = new Set();
      let heroResizeObserver;
      let sidebarStateRetryTimer = 0;
      let sidebarStateRetryCount = 0;
      let sidebarWidthApplied = false;
      let sidebarWidthReported = -1;
      let sidebarWidthReportTimer = 0;

      // The Harness layout store keeps panel geometry in memory, so a dragged sidebar
      // width is gone after a restart. The app stores it and hands it back at document
      // start; the page replays it once through the same drag the user performed, then
      // reports later drags so the app can store those too.
      const sidebarWidthHandlerName = "deepseekStudio";
      const sidebarWidthMessageType = "dshStudio.action";

      const reportSidebarWidth = (width) => {
        if (!Number.isFinite(width) || width <= 0) return;
        if (sidebarWidthReported === width) return;
        sidebarWidthReported = width;
        const handlers = window.webkit && window.webkit.messageHandlers;
        const handler = handlers && handlers[sidebarWidthHandlerName];
        if (!handler) return;
        try {
          handler.postMessage({
            type: sidebarWidthMessageType,
            action: "preference.sync",
            payload: { key: "sidebarWidth", value: width },
          });
        } catch (error) {
          // A page opened without the native bridge simply keeps the width it has.
        }
      };

      const scheduleSidebarWidthReport = (width) => {
        if (sidebarWidthReportTimer !== 0) window.clearTimeout(sidebarWidthReportTimer);
        sidebarWidthReportTimer = window.setTimeout(() => {
          sidebarWidthReportTimer = 0;
          reportSidebarWidth(width);
        }, 250);
      };

      /**
       * Replay a stored width by dragging the panel handle the distance between the
       * current and stored widths. The handle captures the pointer, which a synthetic
       * pointer cannot do, so that one call is stubbed for the duration of the drag: it
       * is bookkeeping for a real pointer, and the store only reads the coordinates.
       */
      const dragSidebarHandle = (handle, delta) => {
        const capture = Element.prototype.setPointerCapture;
        Element.prototype.setPointerCapture = function () {};
        try {
          const origin = handle.getBoundingClientRect().right;
          const shared = {
            bubbles: true,
            cancelable: true,
            composed: true,
            pointerId: 1,
            pointerType: "mouse",
            isPrimary: true,
            button: 0,
          };
          handle.dispatchEvent(new PointerEvent("pointerdown", {
            ...shared, buttons: 1, clientX: origin,
          }));
          handle.dispatchEvent(new PointerEvent("pointermove", {
            ...shared, buttons: 1, clientX: origin + delta,
          }));
          handle.dispatchEvent(new PointerEvent("pointerup", {
            ...shared, buttons: 0, clientX: origin + delta,
          }));
        } finally {
          Element.prototype.setPointerCapture = capture;
        }
      };

      const applyStoredSidebarWidth = (frame, currentWidth) => {
        if (sidebarWidthApplied) return false;
        const stored = Number(window.__deepseekStudioSidebarWidth);
        if (!Number.isFinite(stored) || stored <= 0) {
          sidebarWidthApplied = true;
          return false;
        }
        if (Number.isFinite(currentWidth) && Math.abs(currentWidth - stored) < 1) {
          sidebarWidthApplied = true;
          sidebarWidthReported = Math.round(stored);
          return false;
        }
        const handle = frame.querySelector('[class*="_handle"]');
        if (!handle) return false;
        dragSidebarHandle(handle, stored - currentWidth);
        sidebarWidthApplied = true;
        sidebarWidthReported = Math.round(stored);
        return true;
      };

      const setPixelProperty = (element, name, value) => {
        if (!Number.isFinite(value)) return;
        const next = String(Math.max(0, Math.round(value * 100) / 100)) + "px";
        if (element.style.getPropertyValue(name) !== next) {
          element.style.setProperty(name, next);
        }
      };

      const refreshHeroEntries = () => {
        const nextEntries = [];
        const nextObservedElements = new Set();

        document.querySelectorAll('[data-phase="hero"][class*="_root"]').forEach((root) => {
          const composer = root.querySelector('[class*="_composerHero"]');
          if (!composer) return;

          const row = Array.from(composer.children).find((element) =>
            element.matches('[class*="_heroWorkspaceRow"], [class*="_workspaceRow"]'),
          );
          const card = composer.querySelector('[data-composer-card]');
          if (!row || !card) return;

          nextEntries.push({ root, composer, row, card });

          // The row receives the inset variables below. Observing it would
          // turn our own style writes into another layout pass.
          [root, composer, card].forEach((element) => {
            nextObservedElements.add(element);
            if (!observedHeroElements.has(element)) heroResizeObserver.observe(element);
          });
        });

        observedHeroElements.forEach((element) => {
          if (!nextObservedElements.has(element)) heroResizeObserver.unobserve(element);
        });
        observedHeroElements = nextObservedElements;
        heroEntries = nextEntries;
        heroStructureDirty = false;
      };

      const syncHeroAlignment = () => {
        if (heroStructureDirty) refreshHeroEntries();

        heroEntries.forEach(({ row, card }) => {
          const rowBounds = row.getBoundingClientRect();
          const cardBounds = card.getBoundingClientRect();
          if (rowBounds.width <= 0 || cardBounds.width <= 0) return;

          setPixelProperty(
            row,
            "--deepseek-studio-hero-card-left-inset",
            cardBounds.left - rowBounds.left,
          );
          setPixelProperty(
            row,
            "--deepseek-studio-hero-card-right-inset",
            rowBounds.right - cardBounds.right,
          );
        });
      };

      const scheduleHeroAlignment = () => {
        if (heroAlignmentFrame !== 0) return;
        heroAlignmentFrame = requestAnimationFrame(() => {
          heroAlignmentFrame = 0;
          syncHeroAlignment();
        });
      };

      heroResizeObserver = new ResizeObserver(scheduleHeroAlignment);

      window.__deepseekStudioSetChatContentMaxWidth = (value) => {
        const width = Number(value);
        if (!Number.isFinite(width)) return;
        document.documentElement.style.setProperty(
          "--deepseek-studio-chat-max-width",
          String(width) + "px",
        );
        scheduleHeroAlignment();
      };

      window.__deepseekStudioToggleSidebar = () => {
        const toggle = document.querySelector(
          '[class*="_logoRow"] [class*="_toggle"], ' +
          '[class*="_logoRow"] [aria-label*="sidebar" i], ' +
          '[class*="_logoRow"] [aria-label*="侧边栏"]'
        );
        if (!toggle || typeof toggle.click !== "function") return false;
        toggle.click();
        return true;
      };

      // The app's Settings menu item opens Harness's own settings dialog instead of
      // a second native window, so it presses the trigger Harness already renders in
      // the sidebar. Both the seat and the dialog are Harness-owned contracts.
      const settingsDialogSelector = '[role="dialog"][data-shortcut-modal="settings"]';
      const settingsTriggerSelector =
        '[data-slot="sidebar.settings"] button[aria-haspopup="dialog"], ' +
        '[data-slot="sidebar.settings"] button[aria-expanded]';

      window.__deepseekStudioOpenSettings = () => {
        if (document.querySelector(settingsDialogSelector)) return true;
        const trigger = document.querySelector(settingsTriggerSelector);
        if (!trigger || typeof trigger.click !== "function") return false;
        trigger.click();
        return true;
      };

      const syncSidebarState = () => {
        let foundSidebar = false;
        document.querySelectorAll('[class*="_logoRow"]').forEach((logoRow) => {
          const sidebar = logoRow.parentElement;
          const frame = logoRow.closest('[class*="_frame"]');
          if (!sidebar || !frame) return;
          foundSidebar = true;

          const tracks = getComputedStyle(frame).gridTemplateColumns.trim().split(/\s+/);
          if (tracks.length >= 3) {
            const detailsWidth = tracks[tracks.length - 1];
            if (frame.style.getPropertyValue("--deepseek-studio-details-width") !== detailsWidth) {
              frame.style.setProperty("--deepseek-studio-details-width", detailsWidth);
            }
          }
          const sidebarWidth = tracks.length > 0 ? parseFloat(tracks[0]) : NaN;
          if (!applyStoredSidebarWidth(frame, sidebarWidth)
              && !frame.hasAttribute("data-sidebar-collapsed")) {
            // Only an expanded rail carries the width the user dragged; the collapsed
            // rail is the contract's own 56px and must never be reported as a choice.
            scheduleSidebarWidthReport(Math.round(sidebarWidth));
          }
          const nextSidebarState = frame.hasAttribute("data-sidebar-collapsed")
            ? "collapsed"
            : "expanded";
          if (sidebar.dataset.deepseekStudioSidebar !== nextSidebarState) {
            sidebar.dataset.deepseekStudioSidebar = nextSidebarState;
          }
        });
        return foundSidebar;
      };

      const scheduleSidebarState = () => {
        if (sidebarStateFrame !== 0) return;
        sidebarStateFrame = requestAnimationFrame(() => {
          sidebarStateFrame = 0;
          if (syncSidebarState()) {
            sidebarStateRetryCount = 0;
            return;
          }
          if (sidebarStateRetryCount >= 20 || sidebarStateRetryTimer !== 0) return;
          sidebarStateRetryCount += 1;
          sidebarStateRetryTimer = window.setTimeout(() => {
            sidebarStateRetryTimer = 0;
            scheduleSidebarState();
          }, 50);
        });
      };

      const heroContainerSelector =
        '[data-phase="hero"][class*="_root"], [class*="_composerHero"]';
      const heroEntrySelector =
        '[data-phase="hero"][class*="_root"], [class*="_composerHero"], ' +
        '[class*="_heroWorkspaceRow"], [class*="_workspaceRow"], [data-composer-card]';
      const sidebarEntrySelector =
        '[class*="_frame"], [class*="_logoRow"], [class*="sidebarCol"], [data-pane="sidebar"]';
      const inputScrollSelector = '[data-input-scroll]';
      const nodeMatches = (node, selector) =>
        node.nodeType === 1 && node.matches(selector);
      const subtreeContainsHeroEntry = (node) =>
        nodeMatches(node, heroEntrySelector) ||
        Boolean(node.querySelector?.(heroEntrySelector));
      const mutationChangesHeroStructure = (mutation) => {
        if (mutation.type !== "childList") return false;
        if (nodeMatches(mutation.target, heroContainerSelector)) return true;
        return (
          Array.from(mutation.addedNodes).some(subtreeContainsHeroEntry) ||
          Array.from(mutation.removedNodes).some(subtreeContainsHeroEntry)
        );
      };
      const mutationChangesSidebarStructure = (mutation) => {
        if (mutation.type !== "childList") return false;
        return (
          nodeMatches(mutation.target, sidebarEntrySelector) ||
          Array.from(mutation.addedNodes).some((node) =>
            nodeMatches(node, sidebarEntrySelector) || Boolean(node.querySelector?.(sidebarEntrySelector)),
          ) ||
          Array.from(mutation.removedNodes).some((node) =>
            nodeMatches(node, sidebarEntrySelector) || Boolean(node.querySelector?.(sidebarEntrySelector)),
          )
        );
      };

      // Harness forwards edge wheel events from the composer to the
      // conversation scrollport. Stop that forwarding at the local scrollport
      // while preserving the browser's normal scrolling and default behavior.
      const installInputScrollBoundaryGuard = (element) => {
        if (element.dataset.deepseekStudioInputScrollGuard === "true") return;
        element.dataset.deepseekStudioInputScrollGuard = "true";
        element.addEventListener("wheel", (event) => {
          if (event.deltaY === 0) return;
          const atTop = element.scrollTop <= 0;
          const atEnd = element.scrollTop + element.clientHeight >= element.scrollHeight - 1;
          const movingPastTop = event.deltaY < 0 && atTop;
          const movingPastEnd = event.deltaY > 0 && atEnd;
          if (!movingPastTop && !movingPastEnd) return;
          event.stopImmediatePropagation();
        }, { capture: true });
      };

      const syncInputScrollBoundaryGuards = () => {
        document.querySelectorAll(inputScrollSelector).forEach(installInputScrollBoundaryGuard);
      };
      const mutationAddsInputScroll = (mutation) => {
        if (mutation.type !== "childList") return false;
        return (
          nodeMatches(mutation.target, inputScrollSelector) ||
          Array.from(mutation.addedNodes).some((node) =>
            nodeMatches(node, inputScrollSelector) || Boolean(node.querySelector?.(inputScrollSelector)),
          )
        );
      };

      const observer = new MutationObserver((mutations) => {
        if (mutations.some(mutationChangesHeroStructure)) {
          heroStructureDirty = true;
        }
        if (mutations.some((mutation) => mutation.type === "attributes")) {
          scheduleSidebarState();
        }
        if (mutations.some(mutationChangesSidebarStructure)) {
          scheduleSidebarState();
        }
        if (mutations.some(mutationAddsInputScroll)) {
          syncInputScrollBoundaryGuards();
        }
        if (heroStructureDirty) {
          scheduleHeroAlignment();
        }
      });
      observer.observe(document.documentElement, {
        attributes: true,
        // `data-sidebar-collapsed` marks a panel transition; `style` carries the grid
        // tracks, which is how a width the user dragged reaches this script.
        attributeFilter: ["data-sidebar-collapsed", "style"],
        childList: true,
        subtree: true,
      });
      window.addEventListener("resize", scheduleHeroAlignment);
      syncInputScrollBoundaryGuards();
      scheduleSidebarState();
      scheduleHeroAlignment();
      // Report the width the page starts with, so the app has a value even when no
      // mutation ever triggers another sync pass. The frame can appear well after this
      // script runs — a first-run dialog or a slow plugin can hold the page back — so the
      // attempt is repeated until it lands.
      let sidebarWidthReportAttempts = 0;
      const reportInitialSidebarWidth = () => {
        const frame = document.querySelector('[class*="_frame"]');
        if (!frame) return false;
        const tracks = getComputedStyle(frame).gridTemplateColumns.trim().split(/\s+/);
        const width = tracks.length > 0 ? parseFloat(tracks[0]) : NaN;
        if (!Number.isFinite(width) || width <= 0) return false;
        if (!applyStoredSidebarWidth(frame, width)
            && !frame.hasAttribute("data-sidebar-collapsed")) {
          scheduleSidebarWidthReport(Math.round(width));
        }
        return true;
      };
      const scheduleInitialSidebarWidth = () => {
        sidebarWidthReportAttempts += 1;
        if (reportInitialSidebarWidth() || sidebarWidthReportAttempts >= 20) return;
        window.setTimeout(scheduleInitialSidebarWidth, 750);
      };
      window.setTimeout(scheduleInitialSidebarWidth, 500);
    })();
    """#
}
