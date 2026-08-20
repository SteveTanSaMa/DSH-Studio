//
//  LocalizedUI.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import DeepSeekRuntime
import DeepSeekLogging
import Foundation

/// Keeps user-facing Runtime state and errors out of the lower-level modules.
extension RuntimeState {
    var displayName: String {
        switch self {
        case .idle: return "未启动"
        case .provisioning: return "正在准备运行时"
        case .updating: return "正在更新运行时"
        case .rollingBack: return "正在回滚运行时"
        case .launching: return "正在启动"
        case .starting: return "正在连接"
        case .ready: return "已就绪"
        case .failed: return "启动失败"
        case .stopping: return "正在退出"
        case .terminated: return "已停止"
        case .crashed: return "已崩溃"
        }
    }
}

extension RuntimeError {
    var uiDescription: String {
        switch self {
        case .missingRuntime(let path):
            return "找不到运行时：\(LogRedactor.redactPath(path))"
        case .runtimeProvisioningFailed(let detail):
            return "运行时配置失败：\(LogRedactor.redact(detail))"
        case .invalidRuntime(let detail):
            return "运行时无效：\(LogRedactor.redact(detail))"
        case .nodeVersionMismatch(let expected, let actual):
            return "Node 版本不匹配：期望 \(LogRedactor.redact(expected))，实际 \(LogRedactor.redact(actual))"
        case .harnessVersionMismatch(let expected, let actual):
            return "Harness 版本不匹配：期望 \(LogRedactor.redact(expected))，实际 \(LogRedactor.redact(actual))"
        case .dshHomeFailure(let detail):
            return "Harness 数据目录错误：\(LogRedactor.redact(detail))"
        case .workspaceFailure(let detail):
            return "工作区错误：\(LogRedactor.redact(detail))"
        case .processLaunchFailed(let detail):
            return "进程启动失败：\(LogRedactor.redact(detail))"
        case .readyTimeout(let seconds):
            return "启动超时：\(Int(seconds)) 秒内未就绪"
        case .healthCheckFailed:
            return "健康检查失败"
        case .processCrashed(let status, _):
            return "Harness 进程意外退出，状态码 \(status)"
        }
    }
}
