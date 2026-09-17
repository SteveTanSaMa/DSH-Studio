//
//  DeepSeekHarnessSliceApp.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/21.
//

import AppKit
import SwiftUI

/// Defines the single native window that hosts the local Harness Web UI.
@main
struct DeepSeekHarnessSliceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Declares the single window that hosts the Harness Web UI.
    var body: some Scene {
        WindowGroup {
            ContentView(model: AppDelegate.sharedModel)
                .frame(minWidth: 1024, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 DSH Studio") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }

            CommandGroup(after: .appInfo) {
                Button("检查 Runtime 更新") {
                    AppMenuActions.checkRuntimeVersion()
                }

                Button("打开 DSH 终端") {
                    AppMenuActions.openRuntimeTerminal()
                }
                .disabled(!AppDelegate.sharedModel.runtime.canOpenTerminal)
            }

            CommandGroup(after: .newItem) {
                Button("打开工作区…") {
                    AppMenuActions.chooseWorkspace()
                }

                Button("打开数据文件夹") {
                    AppMenuActions.openDataFolder()
                }
            }

            CommandGroup(after: .saveItem) {
                Button("关闭窗口") {
                    NSApp.keyWindow?.performClose(nil)
                }
            }

            CommandGroup(after: .toolbar) {
                Button("显示/隐藏侧边栏") {
                    HarnessWebView.toggleSidebarOnLiveWebViews()
                }

                Button("刷新 Harness") {
                    HarnessWebView.reloadLiveWebViews()
                }

                Divider()

                Button("进入全屏") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
            }

            CommandGroup(after: .help) {
                Button("DSH Studio 帮助") {
                    NSApp.showHelp(nil)
                }

                Button("打开日志文件夹") {
                    AppMenuActions.openLogs()
                }

                Button("导出诊断包") {
                    AppMenuActions.exportDiagnostics()
                }

                Button("复制诊断信息") {
                    AppMenuActions.copyDiagnostics()
                }
            }
        }

        Settings {
            AppSettingsView(model: AppDelegate.sharedModel)
        }
    }
}

@MainActor
private enum AppMenuActions {
    private static var model: AppModel { AppDelegate.sharedModel }

    static func checkRuntimeVersion() {
        Task { @MainActor in
            let status = await model.checkRuntimeVersion()
            guard let status else {
                showAlert(title: "检查 Runtime 更新失败", message: "无法获取可用 Runtime 信息，请稍后重试或查看日志。")
                return
            }
            if status.updateAvailable {
                showAlert(
                    title: "发现 Runtime 更新",
                    message: "可用版本：\(status.available.runtimeVersion)\n请在设置中完成更新。"
                )
            } else {
                showAlert(title: "Runtime 已是最新版本", message: "当前没有可用的 Runtime 更新。")
            }
        }
    }

    static func chooseWorkspace() {
        Task { @MainActor in
            do {
                _ = try await model.chooseWorkspace()
            } catch {
                showAlert(title: "工作区切换失败", message: error.localizedDescription)
            }
        }
    }

    static func openDataFolder() {
        guard model.openDataFolder() else {
            showAlert(title: "无法打开数据文件夹", message: "请检查数据文件夹是否可访问。")
            return
        }
    }

    static func openRuntimeTerminal() {
        guard model.openRuntimeTerminal() else {
            showAlert(title: "无法打开 DSH 终端", message: "请检查 Runtime 是否已正常启动。")
            return
        }
    }

    static func openLogs() {
        guard model.openLogs() else {
            showAlert(title: "无法打开日志文件夹", message: "请检查应用支持目录是否可访问。")
            return
        }
    }

    static func exportDiagnostics() {
        Task { @MainActor in
            do {
                let url = try await model.exportDiagnostics()
                showAlert(title: "诊断包已导出", message: url.path)
            } catch {
                showAlert(title: "导出诊断包失败", message: error.localizedDescription)
            }
        }
    }

    static func copyDiagnostics() {
        Task { @MainActor in
            let copied = await model.copyDiagnostics()
            showAlert(
                title: copied ? "诊断信息已复制" : "复制诊断信息失败",
                message: copied ? "诊断信息已复制到剪贴板。" : "请稍后重试。"
            )
        }
    }

    private static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
