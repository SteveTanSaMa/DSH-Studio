//
//  RuntimeUpdateCoordinator.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import DeepSeekLogging
import Foundation

/// Coordinates an online Runtime replacement with the Harness process.
///
/// RuntimeProvisioner owns files and directory atomicity. This type owns the
/// app-level sequence: stop the child process, install the candidate, verify
/// that it can become ready, and restore the previous installation if it
/// cannot. Keeping those responsibilities separate makes file operations easy
/// to test without launching a real Harness process.
@MainActor
public final class RuntimeUpdateCoordinator {
    private weak var runtime: RuntimeManager?
    private let updater: any RuntimeUpdating

    init(runtime: RuntimeManager, updater: any RuntimeUpdating) {
        self.runtime = runtime
        self.updater = updater
    }

    public func checkVersion() -> RuntimeVersionStatus {
        let status = updater.versionStatus()
        runtime?.setRuntimeVersionStatus(status)
        return status
    }

    public func update() async throws {
        guard let runtime else {
            throw RuntimeUpdateError.unavailable
        }
        guard runtime.state != .provisioning,
              runtime.state != .updating,
              runtime.state != .rollingBack else {
            throw RuntimeUpdateError.updateFailed("Runtime 当前正在执行其他操作")
        }

        let status = checkVersion()
        guard status.kind != .current else {
            throw RuntimeUpdateError.noUpdateAvailable
        }

        let shouldResume = shouldResume(after: runtime.state)
        if shouldResume {
            await runtime.stop()
        }
        runtime.setRuntimeOperationState(.updating)
        runtime.logs.log(component: "Runtime", level: "info", message: "Runtime update started")

        do {
            let result = try await updater.update()
            runtime.applyRuntimeResult(result)
        } catch {
            runtime.logs.log(
                component: "Runtime",
                level: "error",
                message: "Runtime update failed: \(LogRedactor.redact(error.localizedDescription))"
            )
            await relaunchOldRuntime(runtime, shouldResume: shouldResume)
            throw RuntimeUpdateError.updateFailed(LogRedactor.redact(error.localizedDescription))
        }

        guard shouldResume else {
            runtime.setRuntimeOperationState(.terminated)
            runtime.refreshRuntimeMetadata()
            return
        }

        runtime.setRuntimeOperationState(.terminated)
        runtime.start()
        guard await waitUntilReady(runtime) else {
            runtime.forceStop()
            runtime.logs.log(
                component: "Runtime",
                level: "warn",
                message: "updated Runtime failed to become ready; rolling back"
            )
            do {
                let result = try updater.rollback()
                runtime.applyRuntimeResult(result)
            } catch {
                throw RuntimeUpdateError.rollbackFailed(
                    LogRedactor.redact(error.localizedDescription)
                )
            }

            runtime.setRuntimeOperationState(.terminated)
            runtime.start()
            guard await waitUntilReady(runtime) else {
                runtime.forceStop()
                throw RuntimeUpdateError.rollbackFailed("回滚后的 Runtime 无法启动")
            }
            throw RuntimeUpdateError.updateFailed("新 Runtime 无法启动，已自动回滚")
        }

        runtime.refreshRuntimeMetadata()
        runtime.logs.log(component: "Runtime", level: "info", message: "Runtime update completed")
    }

    public func rollback() async throws {
        guard let runtime else {
            throw RuntimeUpdateError.unavailable
        }
        guard runtime.state != .provisioning,
              runtime.state != .updating,
              runtime.state != .rollingBack else {
            throw RuntimeUpdateError.rollbackFailed("Runtime 当前正在执行其他操作")
        }

        let status = checkVersion()
        guard status.rollbackAvailable else {
            throw RuntimeUpdateError.rollbackUnavailable
        }

        let shouldResume = shouldResume(after: runtime.state)
        if shouldResume {
            await runtime.stop()
        }
        runtime.setRuntimeOperationState(.rollingBack)
        runtime.logs.log(component: "Runtime", level: "info", message: "Runtime rollback started")

        do {
            let result = try updater.rollback()
            runtime.applyRuntimeResult(result)
        } catch {
            await relaunchOldRuntime(runtime, shouldResume: shouldResume)
            throw RuntimeUpdateError.rollbackFailed(LogRedactor.redact(error.localizedDescription))
        }

        guard shouldResume else {
            runtime.setRuntimeOperationState(.terminated)
            runtime.refreshRuntimeMetadata()
            return
        }

        runtime.setRuntimeOperationState(.terminated)
        runtime.start()
        guard await waitUntilReady(runtime) else {
            runtime.forceStop()
            throw RuntimeUpdateError.rollbackFailed("回滚后的 Runtime 无法启动")
        }
        runtime.refreshRuntimeMetadata()
        runtime.logs.log(component: "Runtime", level: "info", message: "Runtime rollback completed")
    }

    private func shouldResume(after state: RuntimeState) -> Bool {
        switch state {
        case .idle, .terminated:
            return false
        case .provisioning, .updating, .rollingBack:
            return false
        case .launching, .starting, .ready, .failed, .crashed, .stopping:
            return true
        }
    }

    private func relaunchOldRuntime(_ runtime: RuntimeManager, shouldResume: Bool) async {
        guard shouldResume else {
            runtime.setRuntimeOperationState(.terminated)
            return
        }
        runtime.setRuntimeOperationState(.terminated)
        runtime.start()
        _ = await waitUntilReady(runtime)
    }

    private func waitUntilReady(_ runtime: RuntimeManager) async -> Bool {
        let timeout = max(runtime.configuration.startupTimeout + 1, 2)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch runtime.state {
            case .ready:
                return true
            case .failed, .crashed:
                return false
            default:
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        return runtime.state == .ready
    }
}
