//
//  RuntimeLocator+Paths.swift
//  DSH Studio
//

import Darwin
import Foundation

/// Filesystem layout of an installed Runtime.
///
/// Every path is derived from a Runtime root so callers never build these paths
/// by hand.
extension RuntimeLocator {
    /// The architecture identifier used by Runtime directories.
    ///
    /// - Returns: `darwin-x64` on an Intel host, otherwise `darwin-arm64`.
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

    /// Path of the bundled Node.js binary.
    ///
    /// - Parameters:
    ///   - root: Runtime installation root.
    ///   - architecture: Architecture directory; defaults to this host's.
    /// - Returns: The expected `node` executable URL.
    public static func nodeExecutable(root: URL, architecture: String = architectureDirectory()) -> URL {
        root
            .appendingPathComponent("node", isDirectory: true)
            .appendingPathComponent(architecture, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("node")
    }

    /// Path of the Harness CLI entry point inside an installation.
    ///
    /// - Parameters:
    ///   - root: Runtime installation root.
    ///   - architecture: Architecture directory; defaults to this host's.
    ///   - harnessVersion: Harness version directory; defaults to the pinned version.
    /// - Returns: The expected `bin.js` entry point URL.
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

    /// Root directory of one Harness version for an architecture.
    ///
    /// - Parameters:
    ///   - root: Runtime installation root.
    ///   - architecture: Architecture directory; defaults to this host's.
    ///   - harnessVersion: Harness version directory; defaults to the pinned version.
    /// - Returns: The expected Harness root URL.
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

    /// Path of the pnpm shim installed for the isolated Harness dependency tree.
    ///
    /// The path stays inside the Runtime so plugin management never falls back to a
    /// Homebrew, Corepack, or otherwise external pnpm.
    ///
    /// - Parameters:
    ///   - root: Runtime installation root.
    ///   - architecture: Architecture directory; defaults to this host's.
    ///   - harnessVersion: Harness version directory; defaults to the pinned version.
    /// - Returns: The expected pnpm shim URL.
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

    /// Path of the installed pnpm package manifest.
    ///
    /// - Parameters:
    ///   - root: Runtime installation root.
    ///   - architecture: Architecture directory; defaults to this host's.
    ///   - harnessVersion: Harness version directory; defaults to the pinned version.
    /// - Returns: The expected `package.json` URL for pnpm.
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

    /// The app's support directory under the user's Application Support folder.
    ///
    /// - Parameter fileManager: File manager used to resolve the directory.
    /// - Returns: `Application Support/DSH Studio`, or `nil` when unavailable.
    public static func applicationSupportDirectory(
        fileManager: FileManager = .default
    ) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DSH Studio", isDirectory: true)
    }

    /// The default Harness data home used when no other home is configured.
    ///
    /// - Parameter fileManager: File manager used to resolve the directory.
    /// - Returns: `Application Support/DSH Studio/DSH_HOME`, or `nil` when unavailable.
    public static func defaultDSHHome(
        fileManager: FileManager = .default
    ) -> URL? {
        applicationSupportDirectory(fileManager: fileManager)?
            .appendingPathComponent("DSH_HOME", isDirectory: true)
    }

    /// The default workspace directory used when the user has not chosen one.
    ///
    /// - Parameter fileManager: File manager used to resolve the directory.
    /// - Returns: `Application Support/DSH Studio/Workspace`, or `nil` when unavailable.
    public static func defaultWorkspace(
        fileManager: FileManager = .default
    ) -> URL? {
        applicationSupportDirectory(fileManager: fileManager)?
            .appendingPathComponent("Workspace", isDirectory: true)
    }

    /// Reads the version reported by a Node.js binary.
    ///
    /// Runs the binary with `--version`, so this is a blocking call.
    ///
    /// - Parameter nodeExecutable: Node.js binary to query.
    /// - Returns: The version without a leading `v`, or `nil` when it cannot be read.
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

    /// Lists the architectures contained in a Mach-O executable.
    ///
    /// Uses `/usr/bin/lipo`, so this is a blocking call.
    ///
    /// - Parameter executable: Executable to inspect.
    /// - Returns: Architecture names, or an empty array when none can be read.
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

    /// Reads the version from the manifest two directories above an entry point.
    ///
    /// - Parameter entry: Harness entry point inside `node_modules/<package>/lib`.
    /// - Returns: The declared version, or `nil` when it cannot be read.
    public static func packageJSONVersion(at entry: URL) -> String? {
        let packageURL = entry
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("package.json")
        return packageJSONVersion(atPackageURL: packageURL)
    }

    /// Reads the version from a package manifest URL directly.
    ///
    /// Separate from the legacy entry-point helper because pnpm is validated from
    /// its package metadata while its npm-created shim lives in `node_modules/.bin`.
    public static func packageJSONVersion(atPackageURL packageURL: URL) -> String? {
        guard let data = try? Data(contentsOf: packageURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String else {
            return nil
        }
        return version
    }
}
