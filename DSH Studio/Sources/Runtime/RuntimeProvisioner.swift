//
//  RuntimeProvisioner.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import CryptoKit
import Foundation

public struct URLSessionRuntimeAssetDownloader: RuntimeAssetDownloading, Sendable {
    public init() {}

    public func download(from url: URL, to destination: URL) async throws {
        // URLSession may follow redirects, so validate both the requested and
        // final response host before moving the archive into staging.
        guard url.scheme == "https",
              url.host == "nodejs.org",
              url.user == nil,
              url.password == nil,
              url.port == nil else {
            throw RuntimeProvisioningError.downloadFailed("Runtime 下载地址不是受信任的 Node.js 官方地址")
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
              httpResponse.url?.scheme == "https",
              httpResponse.url?.host == "nodejs.org",
              (200...299).contains(httpResponse.statusCode) else {
            throw RuntimeProvisioningError.downloadFailed("服务器返回了无效 HTTP 状态")
        }
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            throw RuntimeProvisioningError.downloadFailed(error.localizedDescription)
        }
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
        // stdout is discarded deliberately; only bounded stderr is returned
        // for failure context so install logs cannot grow without a limit.
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        return RuntimeCommandResult(
            status: process.terminationStatus,
            stdout: "",
            stderr: String(data: errorData, encoding: .utf8) ?? ""
        )
    }
}

/// Downloads and installs the fixed Node + Harness dependency graph into
/// Application Support. A complete installation is published only after every
/// file has been verified, so an interrupted first launch cannot be mistaken
/// for a usable Runtime.
public final class RuntimeProvisioner: RuntimeProvisioning, @unchecked Sendable {
    public let root: URL
    public let architecture: String

    private let fileManager: FileManager
    private let bundle: Bundle
    private let downloader: any RuntimeAssetDownloading
    private let commandRunner: any RuntimeCommandRunning
    private let packageLockDataOverride: Data?
    private let nodeArchiveSHA256Override: String?

    public init(
        root: URL,
        architecture: String = RuntimeLocator.architectureDirectory(),
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        downloader: any RuntimeAssetDownloading = URLSessionRuntimeAssetDownloader(),
        commandRunner: any RuntimeCommandRunning = SystemRuntimeCommandRunner(),
        packageLockData: Data? = nil,
        nodeArchiveSHA256Override: String? = nil
    ) {
        self.root = root
        self.architecture = architecture
        self.bundle = bundle
        self.fileManager = fileManager
        self.downloader = downloader
        self.commandRunner = commandRunner
        self.packageLockDataOverride = packageLockData
        self.nodeArchiveSHA256Override = nodeArchiveSHA256Override
    }

    public func provision() async throws -> RuntimeProvisioningResult {
        // Work happens in an isolated staging directory and is published only
        // after checksum, Node, npm, Harness, and native dependency checks.
        guard RuntimeRelease.nodeArchiveURL(architecture: architecture) != nil,
              let releaseSHA256 = RuntimeRelease.nodeArchiveSHA256(architecture: architecture) else {
            throw RuntimeProvisioningError.unsupportedArchitecture(architecture)
        }
        let expectedSHA256 = nodeArchiveSHA256Override ?? releaseSHA256
        if RuntimeLocator.isComplete(
            root: root,
            architecture: architecture,
            fileManager: fileManager,
            expectedNodeSHA256: nodeArchiveSHA256Override
        ) {
            return try existingResult()
        }

        let packageLockData = try loadPackageLockData()
        do {
            try RuntimePackageLockValidator.validate(data: packageLockData)
        } catch let error as RuntimeProvisioningError {
            throw error
        } catch {
            throw RuntimeProvisioningError.invalidPackageLock(error.localizedDescription)
        }

        let parent = root.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".Runtime-\(UUID().uuidString)", isDirectory: true)
        try createDirectory(parent)
        try createDirectory(staging)
        defer {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
        }

        let archive = staging.appendingPathComponent("node.tar.gz", isDirectory: false)
        guard let archiveURL = RuntimeRelease.nodeArchiveURL(architecture: architecture) else {
            throw RuntimeProvisioningError.unsupportedArchitecture(architecture)
        }
        try await downloader.download(from: archiveURL, to: archive)
        let actualSHA256 = try sha256(at: archive)
        guard actualSHA256 == expectedSHA256 else {
            throw RuntimeProvisioningError.checksumMismatch(expected: expectedSHA256, actual: actualSHA256)
        }

        let nodeRoot = RuntimeLocator.nodeExecutable(root: staging, architecture: architecture)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try createDirectory(nodeRoot)
        let tarResult = try commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archive.path, "-C", nodeRoot.path, "--strip-components", "1"],
            currentDirectory: staging,
            environment: commandEnvironment(nodeRoot: nodeRoot)
        )
        guard tarResult.status == 0 else {
            throw RuntimeProvisioningError.commandFailed(status: tarResult.status, detail: summarize(tarResult.stderr))
        }

        let nodeExecutable = RuntimeLocator.nodeExecutable(root: staging, architecture: architecture)
        guard fileManager.isExecutableFile(atPath: nodeExecutable.path),
              RuntimeLocator.nodeVersion(nodeExecutable: nodeExecutable) == RuntimeRelease.nodeVersion else {
            throw RuntimeProvisioningError.runtimeValidationFailed("Node 版本或可执行文件无效")
        }

        let harnessRoot = staging
            .appendingPathComponent("harness", isDirectory: true)
            .appendingPathComponent(architecture, isDirectory: true)
            .appendingPathComponent(RuntimeRelease.harnessVersion, isDirectory: true)
        try createDirectory(harnessRoot)
        try RuntimeRelease.packageJSONData.write(to: harnessRoot.appendingPathComponent("package.json"), options: .atomic)
        try packageLockData.write(to: harnessRoot.appendingPathComponent("package-lock.json"), options: .atomic)

        let npmCLI = nodeRoot.appendingPathComponent("lib/node_modules/npm/bin/npm-cli.js")
        guard fileManager.fileExists(atPath: npmCLI.path) else {
            throw RuntimeProvisioningError.runtimeValidationFailed("官方 Node 发行包缺少 npm")
        }
        let npmResult = try commandRunner.run(
            executable: nodeExecutable,
            arguments: [
                npmCLI.path,
                "ci",
                "--ignore-scripts",
                "--include=optional",
                "--no-audit",
                "--no-fund",
                "--registry", RuntimeRelease.npmRegistryURL.absoluteString
            ],
            currentDirectory: harnessRoot,
            environment: commandEnvironment(nodeRoot: nodeRoot)
        )
        guard npmResult.status == 0 else {
            throw RuntimeProvisioningError.commandFailed(status: npmResult.status, detail: summarize(npmResult.stderr))
        }

        try repairNativePermissions(in: harnessRoot)
        let harnessEntry = RuntimeLocator.harnessEntry(root: staging, architecture: architecture)
        guard fileManager.fileExists(atPath: harnessEntry.path),
              RuntimeLocator.packageJSONVersion(at: harnessEntry) == RuntimeRelease.harnessVersion else {
            throw RuntimeProvisioningError.runtimeValidationFailed("Harness 包入口或版本无效")
        }
        try validateNativeDependencies(in: harnessRoot)

        let manifest = RuntimeInstallationManifest(
            architecture: architecture,
            nodeVersion: RuntimeRelease.nodeVersion,
            harnessVersion: RuntimeRelease.harnessVersion,
            nodeSHA256: expectedSHA256,
            harnessPackageIntegrity: RuntimeRelease.harnessPackageIntegrity
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: RuntimeLocator.runtimeManifestURL(root: staging), options: .atomic)
        try fileManager.removeItem(at: archive)
        try publish(staging: staging)
        return RuntimeProvisioningResult(root: root, architecture: architecture, manifest: manifest)
    }

    private func existingResult() throws -> RuntimeProvisioningResult {
        let url = RuntimeLocator.runtimeManifestURL(root: root)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(RuntimeInstallationManifest.self, from: data) else {
            throw RuntimeProvisioningError.installationFailed("已存在的 Runtime manifest 无法读取")
        }
        return RuntimeProvisioningResult(root: root, architecture: architecture, manifest: manifest)
    }

    private func loadPackageLockData() throws -> Data {
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

    private func createDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw RuntimeProvisioningError.installationFailed(error.localizedDescription)
        }
    }

    private func publish(staging: URL) throws {
        do {
            if fileManager.fileExists(atPath: root.path) {
                _ = try fileManager.replaceItemAt(root, withItemAt: staging, backupItemName: nil, options: [])
            } else {
                try fileManager.moveItem(at: staging, to: root)
            }
        } catch {
            throw RuntimeProvisioningError.installationFailed(error.localizedDescription)
        }
    }

    private func sha256(at url: URL) throws -> String {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        } catch {
            throw RuntimeProvisioningError.downloadFailed(error.localizedDescription)
        }
    }

    private func repairNativePermissions(in harnessRoot: URL) throws {
        let helper = harnessRoot
            .appendingPathComponent("node_modules/node-pty/prebuilds/\(architecture)/spawn-helper")
        guard fileManager.fileExists(atPath: helper.path) else { return }
        do {
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: helper.path)
        } catch {
            throw RuntimeProvisioningError.installationFailed("无法设置 node-pty helper 权限")
        }
    }

    private func validateNativeDependencies(in harnessRoot: URL) throws {
        let nodePtyDirectory = harnessRoot
            .appendingPathComponent("node_modules/node-pty/prebuilds/\(architecture)", isDirectory: true)
        let pty = nodePtyDirectory.appendingPathComponent("pty.node")
        let helper = nodePtyDirectory.appendingPathComponent("spawn-helper")
        guard fileManager.fileExists(atPath: pty.path),
              fileManager.isExecutableFile(atPath: helper.path) else {
            throw RuntimeProvisioningError.runtimeValidationFailed("node-pty 原生依赖不完整")
        }
    }

    private func commandEnvironment(nodeRoot: URL) -> [String: String] {
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

    private func summarize(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 1_500 else { return clean }
        return String(clean.suffix(1_500))
    }
}
