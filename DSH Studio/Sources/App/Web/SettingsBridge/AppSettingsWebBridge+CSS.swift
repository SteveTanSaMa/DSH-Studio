//
//  AppSettingsWebBridge+CSS.swift
//  DSH Studio
//

import Foundation

/// Stylesheet for the injected sections.
///
/// The rules reuse Harness's own design tokens, so the native sections do not
/// look foreign inside its settings page.
extension AppSettingsWebBridge {
    /// The stylesheet applied to the injected settings sections.
    static let appSettingsCSS = #"""
        .dsh-studio-app-settings {
          color: var(--dsw-alias-label-primary);
        }
        .dsh-studio-app-settings-general {
          display: contents;
        }
        .dsh-studio-app-settings * { box-sizing: border-box; }
        .dsh-studio-app-settings-section-divider {
          width: 100%;
          height: 0;
          flex: none;
          border-bottom: 1px solid var(--dsw-alias-border-l2);
        }
        .dsh-studio-app-settings-row {
          display: flex;
          align-items: center;
          gap: 8px;
          min-width: 0;
          padding: 16px 0;
          border-bottom: 1px solid var(--dsw-alias-border-l2);
        }
        .dsh-studio-app-settings-group-title {
          padding: 20px 0 4px;
          color: var(--dsw-alias-label-secondary);
          font-size: 13px;
          font-weight: 500;
          line-height: 20px;
        }
        .dsh-studio-app-settings-notification-row {
          border-bottom: none;
        }
        .dsh-studio-app-settings-notification-row-last {
          border-bottom: 1px solid var(--dsw-alias-border-l2);
        }
        .dsh-studio-app-settings-row-text {
          display: flex;
          flex: 1;
          min-width: 0;
          flex-direction: column;
          gap: 4px;
          padding-right: 48px;
        }
        .dsh-studio-app-settings-title {
          color: var(--dsw-alias-label-primary);
          font-size: 14px;
          font-weight: 400;
          line-height: 22px;
        }
        .dsh-studio-app-settings-detail {
          overflow-wrap: anywhere;
          color: var(--dsw-alias-label-tertiary);
          font-size: 12px;
          font-weight: 400;
          line-height: 18px;
        }
        .dsh-studio-app-settings-button {
          display: inline-flex;
          flex: none;
          align-items: center;
          justify-content: center;
          height: 36px;
          max-width: 45%;
          overflow: hidden;
          padding: 0 14px;
          border: none;
          border-radius: 18px;
          background: var(--dsw-alias-bg-module-platform);
          color: var(--dsw-alias-label-primary);
          cursor: pointer;
          font: inherit;
          font-size: 14px;
          line-height: 22px;
          text-overflow: ellipsis;
          white-space: nowrap;
        }
        .dsh-studio-app-settings-button:hover:not(:disabled) {
          background: var(--dsw-alias-interactive-bg-hover);
        }
        .dsh-studio-app-settings-button:focus-visible,
        .dsh-studio-app-settings-number:focus-visible,
        .dsh-studio-app-settings-select-trigger:focus-visible,
        .dsh-studio-app-settings-switch:focus-visible {
          outline: 1px solid var(--dsw-alias-state-business-primary);
          outline-offset: 1px;
        }
        .dsh-studio-app-settings-button:disabled,
        .dsh-studio-app-settings-number:disabled,
        .dsh-studio-app-settings-select-trigger:disabled,
        .dsh-studio-app-settings-switch:disabled {
          cursor: default;
          opacity: .6;
        }
        .dsh-studio-app-settings-number {
          width: 96px;
          height: 32px;
          flex: none;
          padding: 0 10px;
          border: 1px solid var(--dsw-alias-border-l2);
          border-radius: 8px;
          background: var(--dsw-alias-bg-layer-1);
          color: var(--dsw-alias-label-primary);
          font: inherit;
          font-size: 14px;
          line-height: 22px;
          text-align: right;
        }
        .dsh-studio-app-settings-number::placeholder {
          color: var(--dsw-alias-label-tertiary);
          opacity: 1;
        }
        .dsh-studio-app-settings-select-wrap {
          position: relative;
          flex: none;
        }
        .dsh-studio-app-settings-select-trigger {
          display: inline-flex;
          box-sizing: border-box;
          min-width: 144px;
          height: 36px;
          flex: none;
          align-items: center;
          justify-content: space-between;
          gap: 12px;
          padding: 0 14px;
          border: none;
          border-radius: 18px;
          background: var(--dsw-alias-bg-module-platform);
          color: var(--dsw-alias-label-primary);
          cursor: pointer;
          font: inherit;
          font-size: 14px;
          line-height: 22px;
          white-space: nowrap;
        }
        .dsh-studio-app-settings-select-trigger:hover:not(:disabled) {
          background: var(--dsw-alias-interactive-bg-hover);
        }
        .dsh-studio-app-settings-select-chevron {
          width: 8px;
          height: 8px;
          flex: none;
          margin-top: -4px;
          border-right: 1.5px solid currentColor;
          border-bottom: 1.5px solid currentColor;
          transform: rotate(45deg);
        }
        .dsh-studio-app-settings-select-menu {
          z-index: 100;
          position: absolute;
          top: calc(100% + 4px);
          right: 0;
          box-sizing: border-box;
          min-width: 218px;
          max-width: min(360px, calc(100vw - 32px));
          padding: 4px;
          border: 1px solid var(--dsw-alias-border-inverted);
          border-radius: 12px;
          background: var(--dsw-specific-menu);
          box-shadow: var(--dsw-shadow-lv3);
        }
        .dsh-studio-app-settings-select-menu[hidden] { display: none; }
        .dsh-studio-app-settings-select-option {
          position: relative;
          display: block;
          width: 100%;
          min-height: 40px;
          padding: 8px 34px 8px 10px;
          border: none;
          border-radius: 10px;
          background: transparent;
          color: var(--dsw-alias-label-primary);
          cursor: pointer;
          font: inherit;
          font-size: 14px;
          line-height: 22px;
          text-align: left;
          white-space: nowrap;
        }
        .dsh-studio-app-settings-select-option:hover:not(:disabled) {
          background: var(--dsw-alias-interactive-bg-hover);
        }
        .dsh-studio-app-settings-select-option[aria-selected="true"]::after {
          position: absolute;
          top: 13px;
          right: 12px;
          width: 5px;
          height: 9px;
          border-right: 1.5px solid currentColor;
          border-bottom: 1.5px solid currentColor;
          content: "";
          transform: rotate(45deg);
        }
        .dsh-studio-app-settings-select-option:disabled {
          cursor: not-allowed;
          opacity: .4;
        }
        .dsh-studio-app-settings-switch {
          display: inline-flex;
          flex: none;
          align-items: center;
          justify-content: center;
          width: 52px;
          height: 36px;
          padding: 0;
          border: none;
          border-radius: 999px;
          background: transparent;
          color: var(--dsw-alias-label-primary);
          cursor: pointer;
        }
        .dsh-studio-app-settings-switch-track {
          position: relative;
          display: inline-block;
          width: 32px;
          height: 20px;
          border-radius: 10px;
          background: var(--dsw-alias-border-l2);
          transition: background-color .12s var(--ds-ease-in-out);
        }
        .dsh-studio-app-settings-switch-thumb {
          position: absolute;
          top: 2px;
          left: 2px;
          width: 16px;
          height: 16px;
          border-radius: 50%;
          background: var(--dsw-alias-bg-layer-1);
          transition: transform .12s var(--ds-ease-in-out);
        }
        .dsh-studio-app-settings-switch[aria-checked="true"] .dsh-studio-app-settings-switch-track {
          background: var(--dsw-alias-state-business-primary);
        }
        .dsh-studio-app-settings-switch[aria-checked="true"] .dsh-studio-app-settings-switch-thumb {
          transform: translateX(12px);
        }
        .dsh-studio-app-settings-switch:hover:not(:disabled) .dsh-studio-app-settings-switch-track {
          filter: brightness(.96);
        }
        .dsh-studio-app-settings-status {
          margin: 8px 0 0;
          color: var(--dsw-alias-state-error-primary);
          font-size: 12px;
          line-height: 18px;
        }
        .dsh-studio-app-settings-status[hidden] { display: none; }
    """#
}
