//
//  RuntimeProvisionerUpdates.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import Foundation

/// Version inspection, publication, and rollback operations for RuntimeProvisioner.
extension RuntimeProvisioner {
    func hasImmutableRuntimeVersionConflict(
        with candidateRelease: RuntimeReleaseDescriptor
    ) -> Bool {
        var roots = [
            root,
            RuntimeLocator.candidateRoot(root: root, runtimeVersion: candidateRelease.runtimeVersion)
        ]
        if root.lastPathComponent == "Runtime",
           let versionedRoot = RuntimeLocator.versionedRuntimeRoot(
               supportDirectory: root.deletingLastPathComponent(),
               runtimeVersion: candidateRelease.runtimeVersion
           ) {
            roots.append(versionedRoot)
        }
        for candidateRoot in roots {
            guard let installed = RuntimeLocator.installationManifest(root: candidateRoot),
                  installed.runtimeVersion == candidateRelease.runtimeVersion else {
                continue
            }
            if !installed.matches(candidateRelease) {
                return true
            }
        }
        return false
    }

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
        let candidateRoot = RuntimeLocator.candidateRoot(
            root: root,
            runtimeVersion: release.runtimeVersion
        )
        let prepared = RuntimeLocator.installationManifest(root: candidateRoot)
        let candidateIsComplete = prepared?.matches(release) == true
            && RuntimeLocator.isCompleteInstallation(
                root: candidateRoot,
                architecture: architecture,
                fileManager: fileManager
            )
        let installedIsComplete = installed.map { _ in
            RuntimeLocator.isCompleteInstallation(
                root: root,
                architecture: architecture,
                fileManager: fileManager
            )
        } ?? false
        let installedIsOlder = installed.map {
            RuntimeVersionOrdering.compare($0.runtimeVersion, release.runtimeVersion) == .orderedAscending
        } ?? false
        let activeVersionConflict = installed?.runtimeVersion == release.runtimeVersion
            && installed?.matches(release) == false
        let versionConflict = hasImmutableRuntimeVersionConflict(with: release)
        let kind: RuntimeVersionStatusKind
        if activeVersionConflict {
            kind = .invalid
        } else if versionConflict {
            // A conflicting candidate must not make a healthy active Runtime
            // unlaunchable. Update operations still reject it before any
            // download or activation, but the current Runtime remains usable.
            kind = .updateBlocked
        } else if candidateIsComplete && installedIsComplete && !current && installedIsOlder {
            kind = .updatePrepared
        } else if current {
            kind = .current
        } else if let installed, installedIsComplete, installed.architecture == architecture {
            switch RuntimeVersionOrdering.compare(installed.runtimeVersion, release.runtimeVersion) {
            case .orderedAscending:
                kind = .updateAvailable
            case .orderedSame:
                kind = .invalid
            case .orderedDescending:
                kind = .newerInstalled
            }
        } else if installed == nil && !rootExists {
            kind = .missing
        } else {
            kind = .invalid
        }
        let rollbackRoot = versionedRollbackRoot() ?? RuntimeLocator.rollbackRoot(root: root)
        return RuntimeVersionStatus(
            kind: kind,
            installed: installed,
            available: release,
            prepared: candidateIsComplete ? prepared : nil,
            activeProfileID: dataProfileID,
            activeDataFormatID: dataProfileStore?.dataFormatID(forProfileID: dataProfileID),
            rollbackAvailable: RuntimeLocator.isCompleteInstallation(
                root: rollbackRoot,
                architecture: architecture,
                fileManager: fileManager
            )
        )
    }

    public func rollback() throws -> RuntimeProvisioningResult {
        if let versioned = versionedRollbackRoot() {
            guard RuntimeLocator.isCompleteInstallation(
                root: versioned,
                architecture: architecture,
                fileManager: fileManager
            ) else {
                throw RuntimeProvisioningError.rollbackUnavailable
            }
            root = versioned
            return try existingResult()
        }

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

    func publish(staging: URL, to destination: URL) throws {
        guard destination.standardizedFileURL != root.standardizedFileURL else {
            try publish(staging: staging)
            return
        }
        do {
            let parent = destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            throw RuntimeProvisioningError.installationFailed(error.localizedDescription)
        }
    }

    var versionedSupportDirectory: URL? {
        guard root.deletingLastPathComponent().lastPathComponent == "Runtimes" else {
            return nil
        }
        return root.deletingLastPathComponent().deletingLastPathComponent()
    }

    private func versionedRollbackRoot() -> URL? {
        guard let supportDirectory = versionedSupportDirectory,
              let state = dataProfileStore?.activeState() else {
            return nil
        }

        let currentVersion = RuntimeLocator.installationManifest(root: root)?.runtimeVersion
        let targetVersion = currentVersion == state.runtimeVersion
            ? state.previousRuntimeVersion
            : state.runtimeVersion
        guard let targetVersion,
              targetVersion != currentVersion else { return nil }
        return RuntimeLocator.versionedRuntimeRoot(
            supportDirectory: supportDirectory,
            runtimeVersion: targetVersion
        )
    }
}
