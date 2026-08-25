//
//  RuntimeLocator.swift
//  DSH Studio
//

import Darwin
import Foundation

/// Deterministic discovery of the installed Node and Harness runtime.
public enum RuntimeLocator {
    public static let dshPackageName = "@deepseek-ai/dsh"
    public static let harnessVersion = "0.1.1-rc.2"

    public static func runtimeRoot(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        runtimeVersion: String? = nil,
        supportDirectory: URL? = nil
    ) -> URL {
        if let override = environment["DSH_RUNTIME_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let support = supportDirectory?.standardizedFileURL
            ?? applicationSupportDirectory(fileManager: fileManager) {
            recoverIncompleteActivation(
                supportDirectory: support,
                architecture: architectureDirectory(),
                fileManager: fileManager
            )
            let legacy = support.appendingPathComponent("Runtime", isDirectory: true)
            let activeState = RuntimeDataProfileStore(
                supportDirectory: support,
                fileManager: fileManager
            ).activeState()
            if let activeState,
               let activeRoot = versionedRuntimeRoot(
                   supportDirectory: support,
                   runtimeVersion: activeState.runtimeVersion
               ) {
                if fileManager.fileExists(atPath: activeRoot.path) {
                    return activeRoot
                }
                // A legacy root can be the recoverable half of an interrupted
                // activation. Use it only when its manifest still matches the
                // durable active Runtime version; never fall through to an
                // unrelated legacy installation.
                if installationManifest(root: legacy)?.runtimeVersion == activeState.runtimeVersion {
                    return legacy
                }
                // Keep the active-state target as the repair destination when
                // the expected versioned Runtime is missing.
                return activeRoot
            }
            if fileManager.fileExists(atPath: legacy.path) {
                return legacy
            }
            if let runtimeVersion,
               let versioned = versionedRuntimeRoot(
                   supportDirectory: support,
                   runtimeVersion: runtimeVersion
               ) {
                return versioned
            }
            if let resources = bundle.resourceURL {
                let bundled = resources.appendingPathComponent("Runtime", isDirectory: true)
                if fileManager.fileExists(atPath: bundled.path) {
                    return bundled
                }
            }
            return legacy
        }
        if let resources = bundle.resourceURL {
            let bundled = resources.appendingPathComponent("Runtime", isDirectory: true)
            if fileManager.fileExists(atPath: bundled.path) {
                return bundled
            }
        }
        return URL(fileURLWithPath: "Runtime", isDirectory: true)
    }

    /// Restores the last health-checked Runtime if the process was terminated
    /// after a directory swap but before `active-state.json` could be updated.
    /// The operation is deliberately limited to the app-owned Runtime and its
    /// single rollback copy.
    @discardableResult
    public static func recoverIncompleteActivation(
        supportDirectory: URL,
        architecture: String = architectureDirectory(),
        fileManager: FileManager = .default
    ) -> Bool {
        let store = RuntimeDataProfileStore(
            supportDirectory: supportDirectory,
            fileManager: fileManager
        )
        guard let activeState = store.activeState() else { return false }

        let root = supportDirectory.appendingPathComponent("Runtime", isDirectory: true)
        let backup = rollbackRoot(root: root)
        let rootManifest = installationManifest(root: root)
        let backupManifest = installationManifest(root: backup)
        guard backupManifest?.runtimeVersion == activeState.runtimeVersion,
              isCompleteInstallation(
                  root: backup,
                  architecture: architecture,
                  fileManager: fileManager
              ) else {
            return false
        }

        let rootMatchesActive = rootManifest?.runtimeVersion == activeState.runtimeVersion
            && isCompleteInstallation(
                root: root,
                architecture: architecture,
                fileManager: fileManager
            )
        guard !rootMatchesActive else { return false }

        let displaced = supportDirectory.appendingPathComponent(
            ".Runtime-recovery-\(UUID().uuidString)",
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
            return true
        } catch {
            if fileManager.fileExists(atPath: root.path),
               !fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: root, to: backup)
            }
            if fileManager.fileExists(atPath: displaced.path),
               !fileManager.fileExists(atPath: root.path) {
                try? fileManager.moveItem(at: displaced, to: root)
            }
            return false
        }
    }

    public static func usesDevelopmentOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let root = environment["DSH_RUNTIME_ROOT"] else { return false }
        return !root.isEmpty
    }

    public static func isBundledRuntimeRoot(
        _ root: URL,
        bundle: Bundle = .main
    ) -> Bool {
        guard let resourceURL = bundle.resourceURL else { return false }
        return root.standardizedFileURL == resourceURL
            .appendingPathComponent("Runtime", isDirectory: true)
            .standardizedFileURL
    }

    public static func runtimeManifestURL(root: URL) -> URL {
        root.appendingPathComponent("manifest.json", isDirectory: false)
    }

    public static func runtimesDirectory(supportDirectory: URL) -> URL {
        supportDirectory.standardizedFileURL.appendingPathComponent("Runtimes", isDirectory: true)
    }

    public static func versionedRuntimeRoot(
        supportDirectory: URL,
        runtimeVersion: String
    ) -> URL? {
        guard isSafeRuntimeVersion(runtimeVersion) else { return nil }
        return runtimesDirectory(supportDirectory: supportDirectory)
            .appendingPathComponent(runtimeVersion, isDirectory: true)
    }

    public static func isVersionedRuntimeRoot(
        _ root: URL,
        supportDirectory: URL
    ) -> Bool {
        root.deletingLastPathComponent().standardizedFileURL
            == runtimesDirectory(supportDirectory: supportDirectory).standardizedFileURL
    }

    /// Moves one complete legacy Runtime into its immutable versioned
    /// directory. User data is intentionally outside this operation.
    ///
    /// A legacy installation is left untouched when it is incomplete, its
    /// manifest is unsafe, or the destination already exists. This keeps a
    /// failed migration recoverable and prevents a same-version installation
    /// from being silently overwritten.
    @discardableResult
    public static func migrateLegacyRuntimeIfNeeded(
        supportDirectory: URL,
        architecture: String = architectureDirectory(),
        fileManager: FileManager = .default
    ) -> URL? {
        let supportDirectory = supportDirectory.standardizedFileURL
        let legacyRoot = supportDirectory.appendingPathComponent("Runtime", isDirectory: true)
        let legacyBackup = rollbackRoot(root: legacyRoot)
        let activeState = RuntimeDataProfileStore(
            supportDirectory: supportDirectory,
            fileManager: fileManager
        ).activeState()
        guard fileManager.fileExists(atPath: legacyRoot.path),
              !fileManager.fileExists(atPath: legacyBackup.path),
              let manifest = installationManifest(root: legacyRoot),
              isSafeRuntimeVersion(manifest.runtimeVersion),
              activeState == nil || activeState?.runtimeVersion == manifest.runtimeVersion,
              isCompleteInstallation(
                  root: legacyRoot,
                  architecture: architecture,
                  fileManager: fileManager
              ),
              let destination = versionedRuntimeRoot(
                  supportDirectory: supportDirectory,
                  runtimeVersion: manifest.runtimeVersion
              ),
              !fileManager.fileExists(atPath: destination.path) else {
            return nil
        }

        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: legacyRoot, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}
