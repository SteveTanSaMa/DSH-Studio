//
//  RuntimeUpdateCoordinator+Rollback.swift
//  DSH Studio
//

import DeepSeekLogging
import Foundation

extension RuntimeUpdateCoordinator {
    public func rollback() async throws {
        guard let runtime else {
            throw RuntimeUpdateError.unavailable
        }
        guard !operationInProgress else {
            throw RuntimeUpdateError.rollbackFailed("Runtime 当前正在执行其他操作")
        }
        guard runtime.state != .provisioning,
              runtime.state != .updating,
              runtime.state != .rollingBack else {
            throw RuntimeUpdateError.rollbackFailed("Runtime 当前正在执行其他操作")
        }

        operationInProgress = true
        defer { operationInProgress = false }

        let status = checkVersion()
        guard status.rollbackAvailable else {
            throw RuntimeUpdateError.rollbackUnavailable
        }

        let shouldResume = shouldResume(after: runtime.state)
        let originalProfile = runtime.activeDataProfile
        let originalHomeURL = runtime.configuration.dshHome
        let rollbackProfile = runtime.dataProfileStore?.previousProfile() ?? originalProfile
        if shouldResume {
            await runtime.stop()
        }
        runtime.setRuntimeOperationState(.rollingBack)
        runtime.logs.log(component: "Runtime", level: "info", message: "Runtime rollback started")

        do {
            let result = try updater.rollback()
            runtime.applyRuntimeResult(result)
            runtime.setRuntimeOperationState(.terminated)
            if let rollbackProfile,
               rollbackProfile.homeURL.standardizedFileURL != originalHomeURL.standardizedFileURL {
                try runtime.selectDataProfile(rollbackProfile)
            }
        } catch {
            restoreDataProfile(
                runtime: runtime,
                profile: originalProfile,
                homeURL: originalHomeURL
            )
            await relaunchOldRuntime(runtime, shouldResume: shouldResume)
            throw RuntimeUpdateError.rollbackFailed(LogRedactor.redact(error.localizedDescription))
        }

        guard await verifyActivatedRuntime(runtime, keepRunning: shouldResume) else {
            runtime.forceStop()
            do {
                let result = try updater.rollback()
                restoreDataProfile(
                    runtime: runtime,
                    profile: originalProfile,
                    homeURL: originalHomeURL
                )
                runtime.applyRuntimeResult(result)
            } catch {
                throw RuntimeUpdateError.rollbackFailed(
                    "回滚后的 Runtime 无法启动，且无法恢复原 Runtime：\(LogRedactor.redact(error.localizedDescription))"
                )
            }

            guard shouldResume else {
                runtime.setRuntimeOperationState(.terminated)
                runtime.refreshRuntimeMetadata()
                throw RuntimeUpdateError.rollbackFailed("回滚后的 Runtime 无法启动，已恢复原 Runtime")
            }

            runtime.setRuntimeOperationState(.terminated)
            runtime.start()
            guard await waitUntilReady(runtime) else {
                runtime.forceStop()
                throw RuntimeUpdateError.rollbackFailed("回滚后的 Runtime 无法启动，已恢复原 Runtime")
            }
            throw RuntimeUpdateError.rollbackFailed("回滚后的 Runtime 无法启动，已恢复原 Runtime")
        }
        runtime.refreshRuntimeMetadata()
        runtime.logs.log(component: "Runtime", level: "info", message: "Runtime rollback completed")
    }
}
