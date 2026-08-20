//
//  RuntimeManagerMetadata.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import Foundation

/// RuntimeManager helpers for adopting versioned installations and exposing
/// their metadata to the update coordinator and settings bridge.
extension RuntimeManager {
    func refreshRuntimeVersions() {
        nodeVersion = RuntimeLocator.nodeVersion(nodeExecutable: configuration.nodeExecutable)
        harnessVersion = RuntimeLocator.packageJSONVersion(at: configuration.harnessEntry)
    }

    func adoptInstalledRuntimeIfAvailable() {
        guard let provisioner,
              let manifest = RuntimeLocator.installationManifest(root: provisioner.root),
              RuntimeLocator.isCompleteInstallation(
                  root: provisioner.root,
                  architecture: provisioner.architecture
              ) else {
            return
        }
        configuration.nodeExecutable = RuntimeLocator.nodeExecutable(
            root: provisioner.root,
            architecture: provisioner.architecture
        )
        configuration.pnpmExecutable = RuntimeLocator.pnpmExecutable(
            root: provisioner.root,
            architecture: provisioner.architecture,
            harnessVersion: manifest.harnessVersion
        )
        configuration.harnessEntry = RuntimeLocator.harnessEntry(
            root: provisioner.root,
            architecture: provisioner.architecture,
            harnessVersion: manifest.harnessVersion
        )
        configuration.expectedNodeVersion = manifest.nodeVersion
        configuration.expectedHarnessVersion = manifest.harnessVersion
    }

    func applyRuntimeResult(_ result: RuntimeProvisioningResult) {
        configuration.nodeExecutable = RuntimeLocator.nodeExecutable(
            root: result.root,
            architecture: result.architecture
        )
        configuration.pnpmExecutable = RuntimeLocator.pnpmExecutable(
            root: result.root,
            architecture: result.architecture,
            harnessVersion: result.manifest.harnessVersion
        )
        configuration.harnessEntry = RuntimeLocator.harnessEntry(
            root: result.root,
            architecture: result.architecture,
            harnessVersion: result.manifest.harnessVersion
        )
        configuration.expectedNodeVersion = result.manifest.nodeVersion
        configuration.expectedHarnessVersion = result.manifest.harnessVersion
        refreshRuntimeMetadata()
    }

    /// Refreshes the visible Runtime metadata after an install or rollback.
    func refreshRuntimeMetadata() {
        refreshRuntimeVersions()
        runtimeVersionStatus = runtimeUpdater?.versionStatus()
    }

    func setRuntimeVersionStatus(_ status: RuntimeVersionStatus) {
        runtimeVersionStatus = status
    }

    /// Allows the update coordinator to expose a short-lived operation state.
    func setRuntimeOperationState(_ state: RuntimeState) {
        self.state = state
    }

    public func retry() {
        guard state == .failed || state == .crashed else { return }
        restartTracker.reset()
        restartCount = 0
        start()
    }

    public func updateStartupTimeout(_ timeout: TimeInterval) {
        configuration.startupTimeout = timeout
    }
}
