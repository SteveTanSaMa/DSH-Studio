//
//  RuntimeUpdateCoordinator.swift
//  DSH Studio
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
    /// Manager whose process is stopped around an activation.
    ///
    /// The reference is weak so the coordinator cannot extend its lifetime.
    weak var runtime: RuntimeManager?
    /// Provisioner that owns the actual file and directory operations.
    let updater: any RuntimeUpdating
    /// Guards the app-level sequence so two updates cannot interleave.
    var operationInProgress = false

    /// Whether an update sequence is currently running.
    public var isBusy: Bool {
        operationInProgress
    }

    /// Creates a coordinator for one manager and updater.
    ///
    /// - Parameters:
    ///   - runtime: Manager whose process is coordinated.
    ///   - updater: Provisioner that performs the installation steps.
    init(runtime: RuntimeManager, updater: any RuntimeUpdating) {
        self.runtime = runtime
        self.updater = updater
    }

    /// Refreshes the version comparison and publishes it on the manager.
    ///
    /// - Returns: The comparison produced by the updater.
    public func checkVersion() -> RuntimeVersionStatus {
        let status = updater.versionStatus()
        runtime?.setRuntimeVersionStatus(status)
        return status
    }

    /// Prepares and activates the available update against the current data profile.
    ///
    /// The first call prepares the candidate; a second call performs the profile
    /// switch and activation together.
    ///
    /// - Throws: ``RuntimeUpdateError`` when no update is available, another
    ///   operation is running, or preparation or activation fails.
    public func update() async throws {
        try await update(targetProfile: nil)
    }

    /// Downloads and verifies an available candidate.
    ///
    /// The current Harness process keeps running; activation remains a separate,
    /// explicit step.
    public func prepare() async throws {
        guard let runtime else {
            throw RuntimeUpdateError.unavailable
        }
        guard !operationInProgress else {
            throw RuntimeUpdateError.updateFailed("Runtime 当前正在执行其他操作")
        }
        guard runtime.state != .provisioning,
              runtime.state != .updating,
              runtime.state != .rollingBack else {
            throw RuntimeUpdateError.updateFailed("Runtime 当前正在执行其他操作")
        }

        operationInProgress = true
        defer { operationInProgress = false }

        let status = checkVersion()
        if status.updatePrepared {
            return
        }
        guard status.kind == .updateAvailable,
              let candidateUpdater = updater as? any RuntimeCandidateUpdating else {
            switch status.kind {
            case .current, .newerInstalled:
                throw RuntimeUpdateError.noUpdateAvailable
            case .updateBlocked:
                throw RuntimeUpdateError.runtimeVersionConflict
            default:
                throw RuntimeUpdateError.unavailable
            }
        }
        try await prepareUpdate(
            runtime: runtime,
            updater: candidateUpdater,
            status: status
        )
    }

    /// Activates a prepared Runtime against an explicitly selected data profile.
    ///
    /// The first call still only prepares the candidate; the second call performs
    /// the profile switch and activation together.
    public func update(using profile: RuntimeDataProfile) async throws {
        try await update(targetProfile: profile)
    }

    private func update(targetProfile: RuntimeDataProfile?) async throws {
        guard let runtime else {
            throw RuntimeUpdateError.unavailable
        }
        guard !operationInProgress else {
            throw RuntimeUpdateError.updateFailed("Runtime 当前正在执行其他操作")
        }
        guard runtime.state != .provisioning,
              runtime.state != .updating,
              runtime.state != .rollingBack else {
            throw RuntimeUpdateError.updateFailed("Runtime 当前正在执行其他操作")
        }

        operationInProgress = true
        defer { operationInProgress = false }

        let status = checkVersion()
        guard status.kind == .updateAvailable || status.kind == .updatePrepared else {
            if status.kind == .updateBlocked {
                throw RuntimeUpdateError.runtimeVersionConflict
            }
            throw RuntimeUpdateError.noUpdateAvailable
        }

        if let candidateUpdater = updater as? any RuntimeCandidateUpdating {
            if status.updatePrepared {
                try await activatePreparedUpdate(
                    runtime: runtime,
                    updater: candidateUpdater,
                    status: status,
                    targetProfile: targetProfile
                )
            } else {
                try await prepareUpdate(
                    runtime: runtime,
                    updater: candidateUpdater,
                    status: status
                )
            }
            return
        }

        try await activateLegacyUpdate(runtime: runtime, status: status)
    }
}
