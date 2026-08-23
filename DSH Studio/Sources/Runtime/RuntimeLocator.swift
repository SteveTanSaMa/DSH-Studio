//
//  RuntimeLocator.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import Darwin
import Foundation

/// Deterministic discovery of the installed Node and Harness runtime.
public enum RuntimeLocator {
    public static let dshPackageName = "@deepseek-ai/dsh"
    public static let harnessVersion = "0.1.0-rc.6"

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

    /// The single retained previous installation used by the rollback path.
    public static func rollbackRoot(root: URL) -> URL {
        root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent).backup", isDirectory: true)
    }

    /// Candidate installations are kept outside the active Runtime directory
    /// until the user explicitly activates them.
    public static func candidateRoot(root: URL, runtimeVersion: String) -> URL {
        if root.deletingLastPathComponent().lastPathComponent == "Runtimes",
           isSafeRuntimeVersion(runtimeVersion) {
            return root.deletingLastPathComponent()
                .appendingPathComponent(runtimeVersion, isDirectory: true)
        }
        let safeVersion = runtimeVersion.map { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "." || character == "-" || character == "_")
                ? character
                : "_"
        }
        return root.deletingLastPathComponent()
            .appendingPathComponent(".Runtime-candidate-\(String(safeVersion))", isDirectory: true)
    }

    public static func isSafeRuntimeVersion(_ value: String) -> Bool {
        value != "." && value != ".."
            && !value.isEmpty && value.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_")
            }
    }

    public static func installationManifest(root: URL) -> RuntimeInstallationManifest? {
        guard let data = try? Data(contentsOf: runtimeManifestURL(root: root)) else {
            return nil
        }
        return try? JSONDecoder().decode(RuntimeInstallationManifest.self, from: data)
    }

    public static func isComplete(
        root: URL,
        architecture: String = architectureDirectory(),
        fileManager: FileManager = .default,
        expectedNodeVersion: String = RuntimeRelease.nodeVersion,
        expectedHarnessVersion: String = harnessVersion,
        expectedPnpmVersion: String = RuntimeRelease.pnpmVersion,
        expectedNodeSHA256: String? = nil,
        expectedRelease: RuntimeReleaseDescriptor? = nil
    ) -> Bool {
        // The manifest is the publication marker. Validate it before trusting
        // the executable and dependency tree below the Runtime root.
        guard let manifest = installationManifest(root: root),
              manifest.schemaVersion == RuntimeInstallationManifest.currentSchemaVersion,
              manifest.architecture == architecture,
              !manifest.nodeSHA256.isEmpty,
              !manifest.harnessPackageIntegrity.isEmpty,
              !manifest.pnpmPackageIntegrity.isEmpty,
              fileManager.isExecutableFile(atPath: nodeExecutable(root: root, architecture: architecture).path),
              fileManager.fileExists(atPath: harnessEntry(root: root, architecture: architecture, harnessVersion: expectedHarnessVersion).path),
              fileManager.isExecutableFile(atPath: pnpmExecutable(root: root, architecture: architecture, harnessVersion: expectedHarnessVersion).path),
              nodeVersion(nodeExecutable: nodeExecutable(root: root, architecture: architecture)) == expectedNodeVersion,
              packageJSONVersion(at: harnessEntry(root: root, architecture: architecture, harnessVersion: expectedHarnessVersion)) == expectedHarnessVersion,
              packageJSONVersion(atPackageURL: pnpmPackageJSON(root: root, architecture: architecture, harnessVersion: expectedHarnessVersion)) == expectedPnpmVersion else {
            return false
        }
        if let expectedRelease {
            let expectedNodeSHA256 = expectedNodeSHA256 ?? expectedRelease.nodeArchiveSHA256
            return manifest.architecture == expectedRelease.architecture
                && manifest.runtimeVersion == expectedRelease.runtimeVersion
                && manifest.nodeVersion == expectedRelease.nodeVersion
                && manifest.harnessVersion == expectedRelease.harnessVersion
                && manifest.pnpmVersion == expectedRelease.pnpmVersion
                && manifest.nodeSHA256 == expectedNodeSHA256
                && manifest.harnessPackageIntegrity == expectedRelease.harnessPackageIntegrity
                && manifest.pnpmPackageIntegrity == expectedRelease.pnpmPackageIntegrity
                && manifest.dataFormat == expectedRelease.dataFormat
        }
        return manifest.runtimeVersion == RuntimeRelease.runtimeVersion
            && manifest.nodeSHA256 == (expectedNodeSHA256 ?? RuntimeRelease.nodeArchiveSHA256(architecture: architecture))
            && manifest.harnessPackageIntegrity == RuntimeRelease.harnessPackageIntegrity
            && manifest.pnpmVersion == expectedPnpmVersion
            && manifest.pnpmPackageIntegrity == RuntimeRelease.pnpmPackageIntegrity
    }

    /// Validates a complete installation without requiring it to be the current
    /// app release. This is what makes an older backup eligible for rollback.
    public static func isCompleteInstallation(
        root: URL,
        architecture: String = architectureDirectory(),
        fileManager: FileManager = .default
    ) -> Bool {
        guard let manifest = installationManifest(root: root),
              manifest.schemaVersion == RuntimeInstallationManifest.currentSchemaVersion,
              manifest.architecture == architecture,
              !manifest.nodeSHA256.isEmpty,
              !manifest.harnessPackageIntegrity.isEmpty,
              !manifest.pnpmPackageIntegrity.isEmpty,
              fileManager.isExecutableFile(atPath: nodeExecutable(root: root, architecture: architecture).path),
              fileManager.fileExists(atPath: harnessEntry(root: root, architecture: architecture, harnessVersion: manifest.harnessVersion).path),
              fileManager.isExecutableFile(atPath: pnpmExecutable(root: root, architecture: architecture, harnessVersion: manifest.harnessVersion).path),
              nodeVersion(nodeExecutable: nodeExecutable(root: root, architecture: architecture)) == manifest.nodeVersion,
              packageJSONVersion(at: harnessEntry(root: root, architecture: architecture, harnessVersion: manifest.harnessVersion)) == manifest.harnessVersion,
              packageJSONVersion(atPackageURL: pnpmPackageJSON(root: root, architecture: architecture, harnessVersion: manifest.harnessVersion)) == manifest.pnpmVersion else {
            return false
        }
        return true
    }

    public static func architectureDirectory() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "arm64" }
        let mirror = Mirror(reflecting: info.machine)
        let bytes = mirror.children.map { $0.value as? Int8 ?? 0 }
        let name = String(bytes: bytes.map { UInt8(bitPattern: $0) }, encoding: .ascii)?
            .trimmingCharacters(in: .controlCharacters)
        if name == "x86_64" { return "darwin-x64" }
        return "darwin-arm64"
    }

    public static func nodeExecutable(root: URL, architecture: String = architectureDirectory()) -> URL {
        root
            .appendingPathComponent("node", isDirectory: true)
            .appendingPathComponent(architecture, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("node")
    }

    public static func harnessEntry(
        root: URL,
        architecture: String = architectureDirectory(),
        harnessVersion: String = RuntimeLocator.harnessVersion
    ) -> URL {
        harnessRoot(root: root, architecture: architecture, harnessVersion: harnessVersion)
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(dshPackageName, isDirectory: true)
            .appendingPathComponent("lib", isDirectory: true)
            .appendingPathComponent("bin.js")
    }

    public static func harnessRoot(
        root: URL,
        architecture: String = architectureDirectory(),
        harnessVersion: String = RuntimeLocator.harnessVersion
    ) -> URL {
        root
            .appendingPathComponent("harness", isDirectory: true)
            .appendingPathComponent(architecture, isDirectory: true)
            .appendingPathComponent(harnessVersion, isDirectory: true)
    }

    /// The pnpm shim installed by npm for the isolated Harness dependency tree.
    /// Keeping this path inside the Runtime prevents plugin management from
    /// depending on a user's Homebrew, Corepack, or other external pnpm.
    public static func pnpmExecutable(
        root: URL,
        architecture: String = architectureDirectory(),
        harnessVersion: String = RuntimeLocator.harnessVersion
    ) -> URL {
        harnessRoot(root: root, architecture: architecture, harnessVersion: harnessVersion)
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(".bin", isDirectory: true)
            .appendingPathComponent("pnpm")
    }

    public static func pnpmPackageJSON(
        root: URL,
        architecture: String = architectureDirectory(),
        harnessVersion: String = RuntimeLocator.harnessVersion
    ) -> URL {
        harnessRoot(root: root, architecture: architecture, harnessVersion: harnessVersion)
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("pnpm", isDirectory: true)
            .appendingPathComponent("package.json")
    }

    public static func applicationSupportDirectory(
        fileManager: FileManager = .default
    ) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DSH Studio", isDirectory: true)
    }

    public static func defaultDSHHome(
        fileManager: FileManager = .default
    ) -> URL? {
        applicationSupportDirectory(fileManager: fileManager)?
            .appendingPathComponent("DSH_HOME", isDirectory: true)
    }

    public static func defaultWorkspace(
        fileManager: FileManager = .default
    ) -> URL? {
        applicationSupportDirectory(fileManager: fileManager)?
            .appendingPathComponent("Workspace", isDirectory: true)
    }

    public static func nodeVersion(nodeExecutable: URL) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = nodeExecutable
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let version = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return version?.hasPrefix("v") == true ? String(version!.dropFirst()) : version
        } catch {
            return nil
        }
    }

    public static func architectures(of executable: URL) -> [String] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        process.arguments = ["-archs", executable.path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ")
                .map(String.init) ?? []
        } catch {
            return []
        }
    }

    public static func packageJSONVersion(at entry: URL) -> String? {
        let packageURL = entry
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("package.json")
        return packageJSONVersion(atPackageURL: packageURL)
    }

    /// Reads a package.json URL directly. This is separate from the legacy
    /// entry-point helper because pnpm is validated from its package metadata
    /// while its npm-created shim lives in node_modules/.bin.
    public static func packageJSONVersion(atPackageURL packageURL: URL) -> String? {
        guard let data = try? Data(contentsOf: packageURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String else {
            return nil
        }
        return version
    }
}
