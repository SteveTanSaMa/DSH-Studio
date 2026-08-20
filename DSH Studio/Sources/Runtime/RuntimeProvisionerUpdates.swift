//
//  RuntimeProvisionerUpdates.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import Foundation

/// Version inspection, publication, and rollback operations for RuntimeProvisioner.
extension RuntimeProvisioner {
    public func versionStatus() -> RuntimeVersionStatus {
        let installed = RuntimeLocator.installationManifest(root: root)
        let current = RuntimeLocator.isComplete(
            root: root,
            architecture: architecture,
            expectedNodeVersion: release.nodeVersion,
            expectedHarnessVersion: release.harnessVersion,
            expectedPnpmVersion: release.pnpmVersion,
            expectedNodeSHA256: release.nodeArchiveSHA256,
            expectedRelease: release
        )
        let rootExists = fileManager.fileExists(atPath: root.path)
        let kind: RuntimeVersionStatusKind
        if current {
            kind = .current
        } else if let installed,
                  RuntimeLocator.isCompleteInstallation(
                      root: root,
                      architecture: architecture,
                      fileManager: fileManager
                  ),
                  installed.architecture == architecture {
            kind = .updateAvailable
        } else if installed == nil && !rootExists {
            kind = .missing
        } else {
            kind = .invalid
        }
        return RuntimeVersionStatus(
            kind: kind,
            installed: installed,
            available: release,
            rollbackAvailable: RuntimeLocator.isCompleteInstallation(
                root: RuntimeLocator.rollbackRoot(root: root),
                architecture: architecture,
                fileManager: fileManager
            )
        )
    }

    public func rollback() throws -> RuntimeProvisioningResult {
        let backup = RuntimeLocator.rollbackRoot(root: root)
        guard RuntimeLocator.isCompleteInstallation(
            root: backup,
            architecture: architecture,
            fileManager: fileManager
        ) else {
            throw RuntimeProvisioningError.rollbackUnavailable
        }

        let parent = root.deletingLastPathComponent()
        let displaced = parent.appendingPathComponent(
            ".Runtime-rollback-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            if fileManager.fileExists(atPath: root.path) {
                try fileManager.moveItem(at: root, to: displaced)
            }
            try fileManager.moveItem(at: backup, to: root)
            if fileManager.fileExists(atPath: displaced.path) {
                try fileManager.moveItem(at: displaced, to: backup)
            }
            return try existingResult()
        } catch {
            // Restore the original active/backup pair if the second half of
            // the directory exchange fails.
            if fileManager.fileExists(atPath: root.path),
               !fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: root, to: backup)
            }
            if fileManager.fileExists(atPath: displaced.path),
               !fileManager.fileExists(atPath: root.path) {
                try? fileManager.moveItem(at: displaced, to: root)
            }
            throw RuntimeProvisioningError.rollbackFailed(error.localizedDescription)
        }
    }

    func publish(staging: URL) throws {
        let backup = RuntimeLocator.rollbackRoot(root: root)
        let displaced = root.deletingLastPathComponent()
            .appendingPathComponent(".Runtime-publish-\(UUID().uuidString)", isDirectory: true)
        var activeWasMovedToBackup = false
        var invalidRootWasDisplaced = false

        do {
            // Keep exactly one known-good previous installation. An explicit
            // directory exchange is used instead of replaceItemAt's optional
            // backup name, whose behavior differs for directories across macOS
            // file-system providers.
            if fileManager.fileExists(atPath: backup.path) {
                try fileManager.removeItem(at: backup)
            }

            if fileManager.fileExists(atPath: root.path) {
                if RuntimeLocator.isCompleteInstallation(
                    root: root,
                    architecture: architecture,
                    fileManager: fileManager
                ) {
                    try fileManager.moveItem(at: root, to: backup)
                    activeWasMovedToBackup = true
                } else {
                    try fileManager.moveItem(at: root, to: displaced)
                    invalidRootWasDisplaced = true
                }
            }

            do {
                try fileManager.moveItem(at: staging, to: root)
            } catch {
                if activeWasMovedToBackup,
                   fileManager.fileExists(atPath: backup.path),
                   !fileManager.fileExists(atPath: root.path) {
                    try? fileManager.moveItem(at: backup, to: root)
                } else if invalidRootWasDisplaced,
                          fileManager.fileExists(atPath: displaced.path),
                          !fileManager.fileExists(atPath: root.path) {
                    try? fileManager.moveItem(at: displaced, to: root)
                }
                throw error
            }

            if invalidRootWasDisplaced, fileManager.fileExists(atPath: displaced.path) {
                try fileManager.removeItem(at: displaced)
            }
        } catch {
            throw RuntimeProvisioningError.installationFailed(error.localizedDescription)
        }
    }
}
