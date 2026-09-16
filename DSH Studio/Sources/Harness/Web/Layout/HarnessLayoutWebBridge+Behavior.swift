//
//  HarnessLayoutWebBridge+Behavior.swift
//  DSH Studio
//

import Foundation

extension HarnessLayoutWebBridge {
    static let sourcePartTwo = #"""
      let heroAlignmentFrame = 0;
      let sidebarStateFrame = 0;
      let heroStructureDirty = true;
      let heroEntries = [];
      let observedHeroElements = new Set();
      let heroResizeObserver;
      let sidebarStateRetryTimer = 0;
      let sidebarStateRetryCount = 0;

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
        if (heroStructureDirty) {
          scheduleHeroAlignment();
        }
      });
      observer.observe(document.documentElement, {
        attributes: true,
        attributeFilter: ["data-sidebar-collapsed"],
        childList: true,
        subtree: true,
      });
      window.addEventListener("resize", scheduleHeroAlignment);
      scheduleSidebarState();
      scheduleHeroAlignment();
    })();
    """#
}
