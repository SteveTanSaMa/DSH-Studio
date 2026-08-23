//
//  SessionLogExportWebBridge.swift
//  DSH Studio
//

import Foundation

/// Small host-side bridge for suppressing the Harness-owned browser download
/// feedback modal when the native shell takes over the download.
public enum SessionLogExportWebBridge {
    public static let interceptDialogScript = #"""
    (() => {
      if (window.__deepseekStudioSessionExportInterceptInstalled) return;
      window.__deepseekStudioSessionExportInterceptInstalled = true;

      const hiddenSelector = [
        '[role="dialog"][aria-label="正在导出 Session"]',
        '[role="dialog"][aria-label="Session 导出已开始下载"]',
        '[role="dialog"][aria-label="Exporting Session"]',
        '[role="dialog"][aria-label="Session download started"]',
      ].join(", ");
      const dismissSelector = [
        '[role="dialog"][aria-label="Session 导出已开始下载"]',
        '[role="dialog"][aria-label="Session download started"]',
      ].join(", ");
      const modalRootSelector = [
        '[role="presentation"]:has(> [role="dialog"][aria-label="正在导出 Session"])',
        '[role="presentation"]:has(> [role="dialog"][aria-label="Session 导出已开始下载"])',
        '[role="presentation"]:has(> [role="dialog"][aria-label="Exporting Session"])',
        '[role="presentation"]:has(> [role="dialog"][aria-label="Session download started"])',
      ].join(", ");
      const feedbackTitles = new Set([
        "正在导出 Session",
        "Session 导出已开始下载",
        "Exporting Session",
        "Session download started",
      ]);
      const successTitles = new Set([
        "Session 导出已开始下载",
        "Session download started",
      ]);
      const closeLabels = ["关闭", "Close"];

      // Hide the feedback synchronously at insertion time so it cannot flash
      // before React's close-button handler runs. The outer presentation node
      // must be hidden too because it owns the full-viewport mask.
      const style = document.createElement("style");
      style.dataset.deepseekStudioSessionExportInterception = "true";
      style.textContent = `${hiddenSelector}, ${modalRootSelector} { display: none !important; }`;

      const attachStyle = () => {
        const parent = document.head || document.documentElement;
        if (parent && !style.isConnected) parent.appendChild(style);
      };

      const dismiss = (dialog) => {
        if (dialog.dataset.deepseekStudioSessionExportDismissed === "true") return;
        dialog.dataset.deepseekStudioSessionExportDismissed = "true";
        dialog.style.setProperty("display", "none", "important");
        const modalRoot = dialog.closest('[role="presentation"]');
        modalRoot?.style.setProperty("display", "none", "important");
        const button = Array.from(dialog.querySelectorAll("button")).find((candidate) => {
          const label = (candidate.getAttribute("aria-label") || "").trim();
          const text = (candidate.textContent || "").trim();
          return closeLabels.includes(label) || closeLabels.includes(text);
        });
        if (button) button.click();
      };

      const conceal = (dialog) => {
        dialog.style.setProperty("display", "none", "important");
        const modalRoot = dialog.closest('[role="presentation"]');
        modalRoot?.style.setProperty("display", "none", "important");
      };

      const scan = () => {
        attachStyle();
        document.querySelectorAll('[role="dialog"]').forEach((dialog) => {
          const title = (dialog.getAttribute("aria-label") || "").trim();
          if (!feedbackTitles.has(title)) return;
          conceal(dialog);
          if (successTitles.has(title)) dismiss(dialog);
        });
        // Keep the selector path as a fallback for a dialog whose title is
        // assigned after its first render.
        document.querySelectorAll(dismissSelector).forEach(dismiss);
      };

      const observer = new MutationObserver(scan);
      const start = () => {
        const root = document.documentElement;
        if (!root) {
          document.addEventListener("DOMContentLoaded", start, { once: true });
          return;
        }
        observer.observe(root, {
          attributes: true,
          attributeFilter: ["aria-label"],
          childList: true,
          subtree: true,
        });
        scan();
      };

      attachStyle();
      start();
    })();
    """#
}
