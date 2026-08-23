//
//  HarnessWebBridgeScripts.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import Foundation

/// Small presentation-only DOM adjustments owned by the macOS shell.
///
/// Harness owns the page structure and behavior. These selectors intentionally
/// target the stable semantic fragments exposed by the current UI packages and
/// only change the collapsed rail's presentation inside the native window.
public enum HarnessLayoutWebBridge {
    /// Injects presentation-only CSS and geometry observers into Harness.
    ///
    /// The script deliberately reads rendered bounds rather than reproducing
    /// Harness's layout formula. This keeps the native controls aligned when
    /// the sidebar, window, or Harness's own width setting changes.
    public static let source = #"""
    (() => {
      if (window.__deepseekStudioLayoutInstalled) return;
      window.__deepseekStudioLayoutInstalled = true;

      const style = document.createElement("style");
      style.dataset.deepseekStudioLayoutStyle = "true";
      style.textContent = `
        /* Give the conversation room to grow with the host window while
           retaining a readable lower bound and an App-configurable upper bound. */
        [data-phase][class*="_root"] {
          --dsh-chat-content-width: clamp(748px, calc(100% - 96px), var(--deepseek-studio-chat-max-width, 1000px)) !important;
        }

        /* Keep the controls on Harness's own flex row. The live insets below
           are measured from the rendered composer card because intermediate
           slot wrappers can change their geometry as the column resizes. */
        [data-phase][class*="_root"] [class*="_heroWorkspaceRow"],
        [data-phase][class*="_root"] [class*="_workspaceRow"] {
          box-sizing: border-box !important;
          align-self: stretch !important;
          width: auto !important;
          padding-left: var(--deepseek-studio-hero-card-left-inset, var(--dsh-composer-side-clearance)) !important;
          padding-right: var(--deepseek-studio-hero-card-right-inset, var(--dsh-composer-side-clearance)) !important;
        }

        /* Assistant prose has its own root/body/Markdown subtree. Keep every
           level on the transcript axis so an upstream or theme-specific
           readable-width cap cannot leave the final answer at the old width. */
        [data-chat-flow-kind="assistant-step"],
        [data-chat-flow-kind="assistant-step"] > [class*="_root"],
        [data-chat-flow-kind="assistant-step"] > [class*="_root"] > [class*="_body"],
        [data-chat-flow-kind="assistant-step"] [class*="_markdown"] {
          align-self: stretch !important;
          box-sizing: border-box !important;
          width: 100% !important;
          max-width: none !important;
          min-width: 0 !important;
        }

        /* Skin chrome uses fixed z-index:0 layers. Give the conversation pane
           its own higher stacking context so message surfaces and their hover
           content remain visible across WebKit's composited layers. Keep this
           scoped to the skin and do not promote #root, whose stacking context
           would trap fixed settings dialogs. */
        body[data-dsh-maid-atelier]
          :is([data-pane="conversation"], [class*="centerCol"]) {
          position: relative !important;
          z-index: 1 !important;
        }

        /* Tooltips are fixed-position descendants, but WebKit still honors
           paint clipping on the skin frame and its sidebar column. Release
           those two boundaries so a rail tooltip can cross into the message
           area instead of being cut at the column edge. */
        body[data-dsh-maid-atelier] [class*="_frame"],
        body[data-dsh-maid-atelier]
          :is([data-pane="sidebar"], [class*="sidebarCol"]) {
          overflow: visible !important;
        }

        /* Rail tooltips are mounted next to their anchors. Release the
           sidebar's clipping chain so the two controls in the logo and
           workspace header can paint their hover surfaces outside the local
           36px cells. */
        body[data-dsh-maid-atelier]
          :is([data-pane="sidebar"], [class*="sidebarCol"])
          > div,
        body[data-dsh-maid-atelier]
          :is([data-pane="sidebar"], [class*="sidebarCol"])
          [class*="_regionArea"],
        body[data-dsh-maid-atelier]
          :is([data-pane="sidebar"], [class*="sidebarCol"])
          [class*="_sectionHeader"],
        body[data-dsh-maid-atelier]
          :is([data-pane="sidebar"], [class*="sidebarCol"])
          [class*="_headerActions"],
        body[data-dsh-maid-atelier]
          :is([data-pane="sidebar"], [class*="sidebarCol"])
          [class*="_logoRow"] {
          overflow: visible !important;
        }

        /* Keep the add-workspace and collapse buttons above the skin frame
           even when their own component creates a local stacking context. */
        body[data-dsh-maid-atelier]
          :is([data-pane="sidebar"], [class*="sidebarCol"])
          :is(
            [class*="_headerActions"] [class*="_iconButton"],
            [class*="_logoRow"] [class*="_toggle"]
          ) {
          position: relative !important;
          z-index: 6 !important;
          overflow: visible !important;
        }

        /* The skin gives the two rail branches their own z-index:2 stacking
           contexts. Promote only those branches so their z-index:1200
           tooltips can clear the skin's z-index:4 frame line. */
        body[data-dsh-maid-atelier]
          :is([data-pane="sidebar"], [class*="sidebarCol"])
          > div
          > :is([class*="_regionArea"], [class*="_logoRow"]) {
          position: relative !important;
          z-index: 1200 !important;
        }

        body[data-dsh-maid-atelier]
          :is([data-pane="sidebar"], [class*="sidebarCol"])
          > div:has([role="tooltip"]) {
          z-index: 1200 !important;
        }

        body[data-dsh-maid-atelier]
          :is([data-pane="sidebar"], [class*="sidebarCol"])
          [role="tooltip"] {
          position: fixed !important;
          z-index: 1200 !important;
        }

        /* Keep each workspace group in the same width budget as the session
           list. A theme can make this box percentage-sized, while WebKit's
           scrollbar seat is 8px wide; subtract that seat explicitly so the
           group border cannot jump past the sidebar edge at the overflow
           threshold. */
        [class*="_groupSection"] {
          box-sizing: border-box !important;
          width: calc(100% - var(--dsh-session-list-scrollbar-width, 8px)) !important;
          min-width: 0 !important;
          max-width: calc(100% - var(--dsh-session-list-scrollbar-width, 8px)) !important;
        }
        [class*="_groupSection"] > *,
        [class*="_groupSection"] [role="treeitem"] {
          box-sizing: border-box !important;
          width: 100% !important;
          min-width: 0 !important;
          max-width: 100% !important;
        }
        [class*="_groupSection"] [class*="_sessionOverflowButton"] {
          box-sizing: border-box !important;
          width: 100% !important;
          max-width: 100% !important;
        }

        /* The App uses a hidden title bar, so both sidebar modes need native
           title-bar clearance. */
        [class*="_frame"][data-sidebar-collapsed] {
          grid-template-columns: 80px minmax(0, 1fr) var(--deepseek-studio-details-width, 0px) !important;
        }
        [data-deepseek-studio-sidebar="expanded"] {
          padding-top: 32px !important;
        }
        [data-deepseek-studio-sidebar="collapsed"] {
          box-sizing: border-box !important;
          width: 80px !important;
          min-width: 80px !important;
          flex: 0 0 80px !important;
          align-items: center !important;
          padding: 40px 10px 6px !important;
        }
        [data-deepseek-studio-sidebar="collapsed"] [class*="_logoRow"],
        [data-deepseek-studio-sidebar="collapsed"] [class*="_newSession"],
        [data-deepseek-studio-sidebar="collapsed"] [class*="_footArea"] {
          align-self: center !important;
        }
        [data-deepseek-studio-sidebar="collapsed"] [class*="_logoRow"] {
          width: 36px !important;
          justify-content: center !important;
          padding: 0 !important;
        }
        [data-deepseek-studio-sidebar="collapsed"] [class*="_newSession"] {
          margin-left: 0 !important;
          margin-right: 0 !important;
        }
        [data-deepseek-studio-sidebar="collapsed"] [class*="_regionArea"] {
          width: 100% !important;
          margin-left: 0 !important;
          margin-right: 0 !important;
          padding-left: 0 !important;
          align-items: center !important;
        }
        [data-deepseek-studio-sidebar="collapsed"] [class*="_regionArea"] [class*="_rail"] {
          width: 100% !important;
          align-items: center !important;
        }
        [data-deepseek-studio-sidebar="collapsed"] [class*="_regionArea"] [class*="_rail"] [class*="_sectionHeader"],
        [data-deepseek-studio-sidebar="collapsed"] [class*="_regionArea"] [class*="_rail"] [class*="_search"] {
          align-self: center !important;
          width: 36px !important;
        }
        [data-deepseek-studio-sidebar="collapsed"] [class*="_footArea"] {
          align-items: center !important;
        }

        /* Keep the 36px rail hit targets stable while making the collapsed
           glyphs easier to recognize in the wider native rail. */
        [data-deepseek-studio-sidebar="collapsed"] [class*="_logoRow"] svg,
        [data-deepseek-studio-sidebar="collapsed"] [class*="_newSession"] svg,
        [data-deepseek-studio-sidebar="collapsed"] [class*="_regionArea"] svg,
        [data-deepseek-studio-sidebar="collapsed"] [class*="_footArea"] svg {
          transform: scale(1.15) !important;
          transform-origin: center center !important;
        }
      `;
      (document.head || document.documentElement).appendChild(style);

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
