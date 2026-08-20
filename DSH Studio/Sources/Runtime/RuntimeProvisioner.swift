//
//  RuntimeProvisioner.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import CryptoKit
import Foundation

public struct URLSessionRuntimeAssetDownloader: RuntimeAssetDownloading, Sendable {
    public init() {}

    public func download(from url: URL, to destination: URL) async throws {
        // URLSession may follow redirects, so validate both the requested and
        // final response host before moving an archive into staging.
        guard isAllowedSourceURL(url) else {
            throw RuntimeProvisioningError.downloadFailed("Runtime 下载地址不是受信任的官方地址")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 900
        let (temporaryURL, response): (URL, URLResponse)
        do {
            (temporaryURL, response) = try await URLSession.shared.download(for: request)
        } catch {
            throw RuntimeProvisioningError.downloadFailed(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse,
              let finalURL = httpResponse.url,
              isAllowedFinalURL(finalURL),
              (200...299).contains(httpResponse.statusCode) else {
            throw RuntimeProvisioningError.downloadFailed("服务器返回了无效 HTTP 状态")
        }
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            throw RuntimeProvisioningError.downloadFailed(error.localizedDescription)
        }
    }

    private func isAllowedSourceURL(_ url: URL) -> Bool {
        guard url.scheme == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil else {
            return false
        }
        return url.host == "nodejs.org" || isTrustedGitHubArtifactURL(url)
    }

    private func isAllowedFinalURL(_ url: URL) -> Bool {
        guard url.scheme == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil else {
            return false
        }
        return url.host == "nodejs.org"
            || (url.host == "github.com" && isTrustedGitHubArtifactURL(url))
            || url.host == "release-assets.githubusercontent.com"
    }

    private func isTrustedGitHubArtifactURL(_ url: URL) -> Bool {
        let components = url.path.split(separator: "/")
        return components.count == 6
            && components[0] == "SteveTanSaMa"
            && components[1] == "DSH-Studio"
            && components[2] == "releases"
            && components[3] == "download"
            && components[4].hasPrefix("runtime-")
            && components[5].hasPrefix("dsh-runtime-")
            && components[5].hasSuffix(".tar.gz")
    }
}

public struct RuntimeCommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol RuntimeCommandRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String]
    ) throws -> RuntimeCommandResult
}

public struct SystemRuntimeCommandRunner: RuntimeCommandRunning, Sendable {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String]
    ) throws -> RuntimeCommandResult {
        // Both streams are bounded. stdout is needed for tar archive listings;
        // stderr is retained for failure context without unbounded logs.
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        return RuntimeCommandResult(
            status: process.terminationStatus,
            stdout: bounded(String(data: outputData, encoding: .utf8) ?? ""),
            stderr: bounded(String(data: errorData, encoding: .utf8) ?? "")
        )
    }

    private func bounded(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 100_000 else { return clean }
        return String(clean.prefix(100_000))
    }
}

/// Downloads and installs the fixed Node + Harness dependency graph into
/// Application Support. A complete installation is published only after every
/// file has been verified, so an interrupted first launch cannot be mistaken
/// for a usable Runtime.
public final class RuntimeProvisioner: RuntimeUpdating, @unchecked Sendable {
    public let root: URL
    public let architecture: String
    public let release: RuntimeReleaseDescriptor

    let fileManager: FileManager
    let bundle: Bundle
    let downloader: any RuntimeAssetDownloading
    let commandRunner: any RuntimeCommandRunning
    let packageLockDataOverride: Data?
    let nodeArchiveSHA256Override: String?

    public init(
        root: URL,
        architecture: String = RuntimeLocator.architectureDirectory(),
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        downloader: any RuntimeAssetDownloading = URLSessionRuntimeAssetDownloader(),
        commandRunner: any RuntimeCommandRunning = SystemRuntimeCommandRunner(),
        packageLockData: Data? = nil,
        nodeArchiveSHA256Override: String? = nil,
        release: RuntimeReleaseDescriptor? = nil
    ) {
        self.root = root
        self.architecture = architecture
        self.bundle = bundle
        self.fileManager = fileManager
        self.downloader = downloader
        self.commandRunner = commandRunner
        self.packageLockDataOverride = packageLockData
        self.nodeArchiveSHA256Override = nodeArchiveSHA256Override
        let baseRelease = release ?? Self.releaseDescriptor(architecture: architecture)
        if let nodeArchiveSHA256Override {
            self.release = RuntimeReleaseDescriptor(
                architecture: baseRelease.architecture,
                nodeVersion: baseRelease.nodeVersion,
                harnessVersion: baseRelease.harnessVersion,
                pnpmVersion: baseRelease.pnpmVersion,
                nodeArchiveSHA256: nodeArchiveSHA256Override,
                harnessPackageIntegrity: baseRelease.harnessPackageIntegrity,
                pnpmPackageIntegrity: baseRelease.pnpmPackageIntegrity,
                runtimeVersion: baseRelease.runtimeVersion,
                artifact: baseRelease.artifact
            )
        } else {
            self.release = baseRelease
        }
    }

    public func provision() async throws -> RuntimeProvisioningResult {
        try await install(force: false)
    }

    public func update() async throws -> RuntimeProvisioningResult {
        try await install(force: true)
    }

    private func install(force: Bool) async throws -> RuntimeProvisioningResult {
        if release.artifact != nil {
            return try await installArtifact(force: force)
        }
#if DEBUG
        // The legacy path remains available only for local development while
        // a release artifact is being built. Production apps must ship a
        // catalog entry and never install npm dependencies on the user Mac.
        return try await installLegacy(force: force)
#else
        throw RuntimeProvisioningError.runtimeArtifactUnavailable
#endif
    }

    private static func releaseDescriptor(architecture: String) -> RuntimeReleaseDescriptor {
        guard let release = RuntimeRelease.descriptor(architecture: architecture) else {
            // The initializer cannot throw, so retain a descriptor that will
            // fail the architecture check when provisioning is attempted.
            return RuntimeReleaseDescriptor(
                architecture: architecture,
                nodeVersion: RuntimeRelease.nodeVersion,
                harnessVersion: RuntimeRelease.harnessVersion,
                pnpmVersion: RuntimeRelease.pnpmVersion,
                nodeArchiveSHA256: "",
                harnessPackageIntegrity: RuntimeRelease.harnessPackageIntegrity,
                pnpmPackageIntegrity: RuntimeRelease.pnpmPackageIntegrity
            )
        }
        return release
    }

    func existingResult() throws -> RuntimeProvisioningResult {
        let url = RuntimeLocator.runtimeManifestURL(root: root)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(RuntimeInstallationManifest.self, from: data) else {
            throw RuntimeProvisioningError.installationFailed("已存在的 Runtime manifest 无法读取")
        }
        return RuntimeProvisioningResult(root: root, architecture: architecture, manifest: manifest)
    }

    func loadPackageLockData() throws -> Data {
        if let packageLockDataOverride {
            return packageLockDataOverride
        }
        guard let url = bundle.url(
            forResource: "package-lock",
            withExtension: "json",
            subdirectory: "RuntimeManifest"
        ), let data = try? Data(contentsOf: url) else {
            throw RuntimeProvisioningError.packageLockUnavailable
        }
        return data
    }

    func createDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw RuntimeProvisioningError.installationFailed(error.localizedDescription)
        }
    }

    func sha256(at url: URL) throws -> String {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        } catch {
            throw RuntimeProvisioningError.downloadFailed(error.localizedDescription)
        }
    }

    func repairNativePermissions(in harnessRoot: URL) throws {
        let helper = harnessRoot
            .appendingPathComponent("node_modules/node-pty/prebuilds/\(architecture)/spawn-helper")
        guard fileManager.fileExists(atPath: helper.path) else { return }
        do {
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: helper.path)
        } catch {
            throw RuntimeProvisioningError.installationFailed("无法设置 node-pty helper 权限")
        }
    }

    func validateNativeDependencies(in harnessRoot: URL) throws {
        let nodePtyDirectory = harnessRoot
            .appendingPathComponent("node_modules/node-pty/prebuilds/\(architecture)", isDirectory: true)
        let pty = nodePtyDirectory.appendingPathComponent("pty.node")
        let helper = nodePtyDirectory.appendingPathComponent("spawn-helper")
        guard fileManager.fileExists(atPath: pty.path),
              fileManager.isExecutableFile(atPath: helper.path) else {
            throw RuntimeProvisioningError.runtimeValidationFailed("node-pty 原生依赖不完整")
        }
    }

    func commandEnvironment(nodeRoot: URL) -> [String: String] {
        [
            "HOME": NSHomeDirectory(),
            "PATH": "\(nodeRoot.appendingPathComponent("bin").path):/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
            "npm_config_registry": RuntimeRelease.npmRegistryURL.absoluteString,
            "npm_config_ignore_scripts": "true",
            "npm_config_audit": "false",
            "npm_config_fund": "false",
            "npm_config_update_notifier": "false"
        ]
    }

    func summarize(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 1_500 else { return clean }
        return String(clean.suffix(1_500))
    }
}
