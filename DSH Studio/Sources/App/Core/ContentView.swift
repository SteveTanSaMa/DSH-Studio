//
//  ContentView.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import DeepSeekRuntime
import SwiftUI

/// Renders the native loading/error states around the Harness WebView.
struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var webContentCrashed = false
    @State private var recoveryNotice: String?

    var body: some View {
        // The WebView is mounted only after RuntimeManager reports readiness;
        // this prevents navigation from racing the local server startup.
        ZStack {
            switch model.runtime.state {
            case .idle, .provisioning, .updating, .rollingBack, .launching, .starting:
                ProgressView(progressMessage)
                    .controlSize(.large)
                    .padding()
            case .ready:
                if webContentCrashed {
                    runtimeError("WebView 内容进程已终止")
                } else {
                    HarnessWebView(
                        runtime: model.runtime,
                        model: model,
                        onWebContentTerminated: {
                            webContentCrashed = true
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .failed, .crashed:
                runtimeError(model.runtime.lastError?.uiDescription ?? "Harness 运行失败")
            case .stopping, .terminated:
                Text("正在退出...")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .task {
            model.start()
        }
        .onAppear {
            model.runtime.logs.log(component: "App", level: "info", message: "content view appeared state \(model.runtime.state)")
        }
        .onChange(of: model.runtime.state) { _, _ in
            model.runtime.logs.log(component: "App", level: "info", message: "state \(model.runtime.state)")
        }
    }

    private func runtimeError(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let recoveryNotice {
                Text(recoveryNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            HStack(spacing: 10) {
                Button("重试") {
                    recoveryNotice = nil
                    webContentCrashed = false
                    model.runtime.retry()
                }
                Button("复制诊断") {
                    Task {
                        recoveryNotice = await model.copyDiagnostics()
                            ? "诊断信息已复制"
                            : "无法复制诊断信息"
                    }
                }
                Button("导出诊断包") {
                    Task {
                        do {
                            let url = try await model.exportDiagnostics()
                            recoveryNotice = "已保存：\(url.lastPathComponent)"
                        } catch {
                            recoveryNotice = error.localizedDescription
                        }
                    }
                }
                Button("打开日志") {
                    recoveryNotice = model.openLogs() ? "已打开日志文件夹" : "无法打开日志文件夹"
                }
            }
            if model.runtime.runtimeVersionStatus?.rollbackAvailable == true {
                Button("恢复上一版 Runtime") {
                    Task {
                        do {
                            try await model.rollbackRuntime()
                            recoveryNotice = "Runtime 已恢复，请重试启动"
                        } catch {
                            recoveryNotice = error.localizedDescription
                        }
                    }
                }
            }
        }
        .padding()
    }

    private var progressMessage: String {
        switch model.runtime.state {
        case .provisioning:
            return "正在准备 DSH Studio 运行时..."
        case .updating:
            return "正在更新 DSH Studio 运行时..."
        case .rollingBack:
            return "正在恢复 DSH Studio 运行时..."
        default:
            return "正在启动 DSH Studio..."
        }
    }
}
