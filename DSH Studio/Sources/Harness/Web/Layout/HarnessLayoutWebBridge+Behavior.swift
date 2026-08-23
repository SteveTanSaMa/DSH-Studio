//
//  HarnessLayoutWebBridge+Behavior.swift
//  DSH Studio
//

import Foundation

extension HarnessLayoutWebBridge {
    static let sourcePartTwo = #"""
      let heroAlignmentFrame = 0;
      let observedHeroElements = new Set();
      let heroResizeObserver;

      const setPixelProperty = (element, name, value) => {
        if (!Number.isFinite(value)) return;
        const next = String(Math.max(0, Math.round(value * 100) / 100)) + "px";
        if (element.style.getPropertyValue(name) !== next) {
          element.style.setProperty(name, next);
        }
      };

      const syncHeroAlignment = () => {
        const nextObservedElements = new Set();

        document.querySelectorAll('[data-phase="hero"][class*="_root"]').forEach((root) => {
          const composer = root.querySelector('[class*="_composerHero"]');
          if (!composer) return;

          const row = Array.from(composer.children).find((element) =>
            element.matches('[class*="_heroWorkspaceRow"], [class*="_workspaceRow"]'),
          );
          const card = composer.querySelector('[data-composer-card]');
          if (!row || !card) return;

          [root, composer, row, card].forEach((element) => {
            nextObservedElements.add(element);
            if (!observedHeroElements.has(element)) heroResizeObserver.observe(element);
          });

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

        observedHeroElements.forEach((element) => {
          if (!nextObservedElements.has(element)) heroResizeObserver.unobserve(element);
        });
        observedHeroElements = nextObservedElements;
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

      const syncSidebarState = () => {
        document.querySelectorAll('[class*="_logoRow"]').forEach((logoRow) => {
          const sidebar = logoRow.parentElement;
          const frame = logoRow.closest('[class*="_frame"]');
          if (!sidebar || !frame) return;

          const tracks = getComputedStyle(frame).gridTemplateColumns.trim().split(/\s+/);
          if (tracks.length >= 3) {
            frame.style.setProperty(
              "--deepseek-studio-details-width",
              tracks[tracks.length - 1],
            );
          }
          sidebar.dataset.deepseekStudioSidebar = frame.hasAttribute("data-sidebar-collapsed")
            ? "collapsed"
            : "expanded";
        });
      };

      const observer = new MutationObserver(() => {
        syncSidebarState();
        scheduleHeroAlignment();
      });
      observer.observe(document.documentElement, {
        attributes: true,
        attributeFilter: ["data-sidebar-collapsed"],
        childList: true,
        subtree: true,
      });
      window.addEventListener("resize", scheduleHeroAlignment);
      syncSidebarState();
      scheduleHeroAlignment();
    })();
    """#
}
