//
//  AppSettingsWebBridge+CSS.swift
//  DSH Studio
//

import Foundation

extension AppSettingsWebBridge {
    static let appSettingsCSS = #"""
        .dsh-studio-app-settings {
          display: contents;
          color: var(--dsw-alias-label-primary);
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
        .dsh-studio-app-settings-row.last-row {
          border-bottom: none;
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
          font-size: 14px;
          font-weight: 400;
          line-height: 22px;
          color: var(--dsw-alias-label-primary);
        }
        .dsh-studio-app-settings-detail {
          overflow-wrap: anywhere;
          font-size: 12px;
          font-weight: 400;
          line-height: 18px;
          color: var(--dsw-alias-label-tertiary);
        }
        .dsh-studio-app-settings-value {
          flex: none;
          max-width: 48%;
          overflow-wrap: anywhere;
          font-size: 14px;
          line-height: 22px;
          color: var(--dsw-alias-label-secondary);
          text-align: right;
        }
        .dsh-studio-app-settings-button {
          display: inline-flex;
          flex: none;
          align-items: center;
          justify-content: center;
          height: 36px;
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
        .dsh-studio-app-settings-button:hover:not(:disabled) {
          background: var(--dsw-alias-interactive-bg-hover);
        }
        .dsh-studio-app-settings-actions {
          display: flex;
          flex: none;
          flex-wrap: wrap;
          justify-content: flex-end;
          gap: 6px;
        }
        .dsh-studio-app-settings-button:focus-visible,
        .dsh-studio-app-settings-number:focus-visible {
          outline: 1px solid var(--dsw-alias-state-business-primary);
          outline-offset: 1px;
        }
        .dsh-studio-app-settings-button:disabled,
        .dsh-studio-app-settings-number:disabled {
          cursor: default;
          opacity: .6;
        }
        .dsh-studio-app-settings-number {
          box-sizing: border-box;
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
        .dsh-studio-app-settings-select-trigger:focus-visible,
        .dsh-studio-app-settings-switch:focus-visible {
          outline: 1px solid var(--dsw-alias-state-business-primary);
          outline-offset: 1px;
        }
        .dsh-studio-app-settings-select-trigger:disabled,
        .dsh-studio-app-settings-switch:disabled {
          cursor: default;
          opacity: .6;
        }
        .dsh-studio-app-settings-select-chevron {
          box-sizing: border-box;
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
          box-sizing: border-box;
          position: absolute;
          top: calc(100% + 4px);
          right: 0;
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
          width: 36px;
          height: 32px;
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
          width: 20px;
          height: 10px;
          border-radius: 5px;
          background: var(--dsw-alias-border-l2);
          transition: background-color .12s var(--ds-ease-in-out);
        }
        .dsh-studio-app-settings-switch-thumb {
          position: absolute;
          top: 2px;
          left: 2px;
          width: 6px;
          height: 6px;
          border-radius: 50%;
          background: var(--dsw-alias-bg-layer-1);
          transition: transform .12s var(--ds-ease-in-out);
        }
        .dsh-studio-app-settings-switch[aria-checked="true"] .dsh-studio-app-settings-switch-track {
          background: var(--dsw-alias-state-business-primary);
        }
        .dsh-studio-app-settings-switch[aria-checked="true"] .dsh-studio-app-settings-switch-thumb {
          transform: translateX(10px);
        }
        .dsh-studio-app-settings-switch:hover:not(:disabled) .dsh-studio-app-settings-switch-track {
          filter: brightness(.96);
        }
        .dsh-studio-app-settings-version-actions {
          display: flex;
          flex: none;
          align-items: center;
          gap: 8px;
          margin-left: auto;
        }
        .dsh-studio-app-settings-status {
          margin: 8px 0 0;
          font-size: 12px;
          line-height: 18px;
        }
        .dsh-studio-app-settings-status[hidden] { display: none; }
        .dsh-studio-app-settings-status[data-kind="error"] { color: var(--dsw-alias-state-error-primary); }
        @media (max-width: 720px) {
          .dsh-studio-app-settings-row-text { padding-right: 16px; }
          .dsh-studio-app-settings-value { max-width: 42%; }
          .dsh-studio-app-settings-actions { max-width: 50%; }
        }
    """#
}
