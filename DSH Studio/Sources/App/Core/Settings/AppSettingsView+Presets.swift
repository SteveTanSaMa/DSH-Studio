//
//  AppSettingsView+Presets.swift
//  DSH Studio
//

import DeepSeekRuntime
import SwiftUI

/// Agent Presets: moving user presets in and out of the app, plus what is
/// currently installed.
extension AppSettingsView {
    @ViewBuilder
    var presetPane: some View {
        SettingsGroup(
            header: "导入与导出",
            footer: "仅用户创建的 Agent Preset 可以导入或导出。"
        ) {
            SettingsActionRow(
                title: "导入 Agent Preset",
                description: "从 .dshpreset 压缩包安装用户 Preset",
                actionTitle: "导入…",
                accessibilityLabel: "导入 Agent Preset",
                isBusy: operation == .importingPreset
            ) {
                importPreset()
            }

            SettingsActionRow(
                title: "导出 Agent Preset",
                description: "将用户 Preset 导出为 .dshpreset 压缩包",
                actionTitle: "导出…",
                accessibilityLabel: "导出 Agent Preset",
                isBusy: operation == .exportingPreset
            ) {
                exportPreset()
            }
        }

        SettingsGroup(header: "用户 Preset") {
            if userPresets.isEmpty {
                HStack(spacing: 0) {
                    Text("暂无用户 Preset")
                        .font(SettingsDesign.titleFont)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, SettingsDesign.rowHorizontalPadding)
                .padding(.vertical, SettingsDesign.rowVerticalPadding)
                .frame(minHeight: SettingsDesign.rowMinHeight)
            } else {
                ForEach(userPresets, id: \.id) { preset in
                    SettingsRow(
                        title: preset.name,
                        description: statusText(for: preset),
                        problem: preset.problem
                    ) {
                        Text(preset.status.displayName)
                            .font(SettingsDesign.detailFont)
                            .foregroundStyle(preset.status == .ready ? Color.secondary : Color.red)
                    }
                }
            }
        }
    }

    var userPresets: [AgentPresetSummary] {
        model.presetTransfer.summaries()
    }
}
