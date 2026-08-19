//
//  ContentView.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import DeepSeekRuntime
import SwiftUI

/// Renders the native loading/error states around the Harness WebView.
struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var webContentCrashed = false

    var body: some View {
        // The WebView is mounted only after RuntimeManager reports readiness;
        // this prevents navigation from racing the local server startup.
        ZStack {
            switch model.runtime.state {
            case .idle, .provisioning, .launching, .starting:
                ProgressView(model.runtime.state == .provisioning ? "正在准备 DSH Studio 运行时..." : "正在启动 DSH Studio...")
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
            Button("重试") {
                webContentCrashed = false
                model.runtime.retry()
            }
        }
        .padding()
    }
}
