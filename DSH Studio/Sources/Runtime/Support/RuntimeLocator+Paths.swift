//
//  RuntimeLocator+Paths.swift
//  DSH Studio
//

import Darwin
import Foundation

extension RuntimeLocator {
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
