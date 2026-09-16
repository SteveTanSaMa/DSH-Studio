//
//  AppSettingsView+Profiles.swift
//  DSH Studio
//

import DeepSeekRuntime
import SwiftUI

/// Harness Profiles: which composition is active, what else is installed, and
/// the two operations that change the set of profiles.
extension AppSettingsView {
    @ViewBuilder
    var profilePane: some View {
        SettingsGroup(
            header: "当前 Profile",
            footer: "Profile 用于隔离 Harness 的插件和界面组合，切换会重启 Harness。"
        ) {
            SettingsRow(title: "使用中的 Profile") {
                Picker("当前 Profile", selection: activeProfileBinding) {
                    ForEach(harnessProfiles, id: \.name) { profile in
                        Text(profile.name)
                            .tag(profile.name)
                            .disabled(!profile.selectable)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(isBusy)
            }
        }

        SettingsGroup(header: "已安装的 Profile") {
            ForEach(harnessProfiles, id: \.name) { profile in
                SettingsRow(
                    title: profile.name,
                    description: profileDetail(profile),
                    problem: profile.problem
                ) {
                    Text(model.harnessProfiles.status(for: profile.name).displayName)
                        .font(SettingsDesign.detailFont)
                        .foregroundStyle(profile.selectable ? Color.secondary : Color.red)
                }
            }
        }

        SettingsGroup(header: "管理") {
            SettingsRow(
                title: "新建 Profile",
                description: "名称只能包含字母、数字、短横线、下划线和点"
            ) {
                HStack(spacing: 8) {
                    TextField("Profile 名称", text: $newProfileName, prompt: Text("Profile 名称"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .frame(minWidth: 120, maxWidth: 200)
                        .disabled(isBusy)
                        .onSubmit { createProfile() }
                        .accessibilityLabel("新建 Profile 名称")
                    SettingsActionButton(
                        title: "创建",
                        isEnabled: !isBusy && !trimmedNewProfileName.isEmpty,
                        accessibilityLabel: "创建 Profile"
                    ) {
                        createProfile()
                    }
                }
            }

            SettingsActionRow(
                title: "删除当前 Profile",
                description: "默认 Profile 不能删除，删除后无法恢复",
                actionTitle: "删除…",
                accessibilityLabel: "删除当前 Profile",
                role: .destructive,
                isEnabled: canDeleteCurrentProfile,
                isBusy: operation == .deletingProfile
            ) {
                requestProfileDeletion()
            }
        }
    }

    var harnessProfiles: [HarnessProfile] {
        model.harnessProfiles.profiles()
    }
}
