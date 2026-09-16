//
//  AppSettingsView+Runtime.swift
//  DSH Studio
//

import DeepSeekRuntime
import SwiftUI

/// Runtime: what is installed, what is running, and the maintenance actions.
/// Versions and status are read-only rows; every state change stays behind an
/// explicit button.
extension AppSettingsView {
    @ViewBuilder
    var runtimePane: some View {
        SettingsGroup(header: "版本") {
            SettingsValueRow(
                title: "当前 Harness",
                value: model.runtime.harnessVersion ?? "未安装"
            )
            SettingsValueRow(
                title: "当前 Runtime",
                value: installedRuntimeVersion
            )
            SettingsValueRow(
                title: "运行状态",
                value: installedRuntimeState,
                isBusy: runtimeBusy
            )
            SettingsValueRow(
                title: "更新状态",
                value: runtimeVersionState,
                isBusy: operation == .checkingRuntimeUpdate
            )
            if let available = model.latestSignedHarnessVersion {
                SettingsValueRow(title: "可用 Harness", value: available)
            }
        }

        SettingsGroup(
            header: "维护",
            footer: "Runtime 更新会在完成验证后切换，失败时保留可恢复状态。"
        ) {
            SettingsActionRow(
                title: "检查更新",
                description: "从签名目录获取可用版本信息",
                actionTitle: "检查更新",
                accessibilityLabel: "检查 Runtime 更新",
                isEnabled: !runtimeBusy,
                isBusy: operation == .checkingRuntimeUpdate
            ) {
                checkRuntime()
            }

            SettingsActionRow(
                title: "安装更新",
                description: runtimeUpdateDescription,
                actionTitle: "更新",
                accessibilityLabel: "安装 Runtime 更新",
                isEnabled: !runtimeBusy && model.hasVerifiedRuntimeUpdate,
                isBusy: operation == .updatingRuntime
            ) {
                updateRuntime()
            }

            SettingsActionRow(
                title: "恢复上一版",
                description: "回滚到上一个已安装的 Runtime 构建",
                actionTitle: "恢复上一版",
                accessibilityLabel: "恢复上一版 Runtime",
                isEnabled: !runtimeBusy && model.runtime.runtimeVersionStatus?.rollbackAvailable == true,
                isBusy: operation == .rollingBackRuntime
            ) {
                rollbackRuntime()
            }
        }
    }
}
