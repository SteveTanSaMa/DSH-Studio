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
        fileManager: FileManager = .default
    ) -> URL {
        if let override = environment["DSH_RUNTIME_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let support = applicationSupportDirectory(fileManager: fileManager) {
            let installed = support.appendingPathComponent("Runtime", isDirectory: true)
            if fileManager.fileExists(atPath: installed.path) {
                return installed
            }
            if let resources = bundle.resourceURL {
                let bundled = resources.appendingPathComponent("Runtime", isDirectory: true)
                if fileManager.fileExists(atPath: bundled.path) {
                    return bundled
                }
            }
            return installed
        }
        if let resources = bundle.resourceURL {
            let bundled = resources.appendingPathComponent("Runtime", isDirectory: true)
            if fileManager.fileExists(atPath: bundled.path) {
                return bundled
            }
        }
        return URL(fileURLWithPath: "Runtime", isDirectory: true)
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

    /// The single retained previous installation used by the rollback path.
    public static func rollbackRoot(root: URL) -> URL {
        root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent).backup", isDirectory: true)
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
