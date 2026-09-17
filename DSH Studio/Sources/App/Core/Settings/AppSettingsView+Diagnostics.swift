//
//  AppSettingsView+Diagnostics.swift
//  DSH Studio
//

import SwiftUI

/// Diagnostics and the two support tools that live outside the app bundle.
extension AppSettingsView {
    /// The Diagnostics category: bundle export, logs, and the scoped terminal.
    @ViewBuilder
    var diagnosticPane: some View {
        SettingsGroup(
            header: "诊断",
            footer: "诊断包包含经过脱敏的 Runtime、Profile、Preset 和日志信息。"
        ) {
            SettingsActionRow(
                title: "导出诊断包",
                description: "包含脱敏的 Runtime、Profile、Preset 与日志",
                actionTitle: "导出…",
                accessibilityLabel: "导出诊断包",
                isBusy: operation == .exportingDiagnostics
            ) {
                exportDiagnostics()
            }

            SettingsActionRow(
                title: "复制诊断信息",
                description: "复制纯文本诊断摘要到剪贴板",
                actionTitle: "复制",
                accessibilityLabel: "复制诊断信息",
                isBusy: operation == .copyingDiagnostics
            ) {
                copyDiagnostics()
            }
        }

        SettingsGroup(header: "工具") {
            SettingsActionRow(
                title: "打开日志文件夹",
                actionTitle: "打开",
                accessibilityLabel: "打开日志文件夹",
                isBusy: operation == .openingLogs
            ) {
                openLogs()
            }

            SettingsActionRow(
                title: "打开 DSH 终端",
                description: "终端已配置 DSH_HOME、Profile 与当前工作区",
                actionTitle: "打开",
                accessibilityLabel: "打开 DSH 终端",
                isEnabled: model.runtime.canOpenTerminal,
                isBusy: operation == .openingTerminal
            ) {
                openTerminal()
            }
        }
    }
}
