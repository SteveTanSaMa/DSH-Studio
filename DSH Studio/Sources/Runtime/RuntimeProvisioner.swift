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
            && components[1] == "DSH-Studio-Runtime"
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

private final class RuntimePipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collectedData = Data()

    func drain(_ handle: FileHandle) {
        let data = handle.readDataToEndOfFile()
        lock.lock()
        collectedData = data
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return collectedData
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
        // Drain both pipes while the process runs. Waiting for exit first can
        // deadlock when a command such as tar -tzf fills its stdout pipe.
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputCollector = RuntimePipeCollector()
        let errorCollector = RuntimePipeCollector()
        let drainGroup = DispatchGroup()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()

        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputCollector.drain(outputPipe.fileHandleForReading)
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errorCollector.drain(errorPipe.fileHandleForReading)
            drainGroup.leave()
        }

        process.waitUntilExit()
        drainGroup.wait()
        return RuntimeCommandResult(
            status: process.terminationStatus,
            stdout: String(data: outputCollector.data(), encoding: .utf8) ?? "",
            stderr: bounded(String(data: errorCollector.data(), encoding: .utf8) ?? "")
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
public final class RuntimeProvisioner: RuntimeCandidateUpdating, RuntimeDataProfileSelecting, RuntimeReleaseUpdating, @unchecked Sendable {
    public internal(set) var root: URL
    public let architecture: String
    public private(set) var release: RuntimeReleaseDescriptor
    public let dataProfileStore: RuntimeDataProfileStore?
    private var selectedDataProfileID: String?

    public var dataProfileID: String? {
        selectedDataProfileID ?? dataProfileStore?.activeState()?.profileID
    }

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
        release: RuntimeReleaseDescriptor? = nil,
        dataProfileStore: RuntimeDataProfileStore? = nil,
        dataProfileID: String? = nil
    ) {
        self.root = root
        self.architecture = architecture
        self.bundle = bundle
        self.fileManager = fileManager
        self.downloader = downloader
        self.commandRunner = commandRunner
        self.packageLockDataOverride = packageLockData
        self.nodeArchiveSHA256Override = nodeArchiveSHA256Override
        self.dataProfileStore = dataProfileStore
        self.selectedDataProfileID = dataProfileID
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
                artifact: baseRelease.artifact,
                dataFormat: baseRelease.dataFormat
            )
        } else {
            self.release = baseRelease
        }
    }

    public func provision() async throws -> RuntimeProvisioningResult {
        guard !hasImmutableRuntimeVersionConflict(with: release) else {
            throw RuntimeProvisioningError.runtimeValidationFailed(
                "同一 Runtime 版本的内容不一致，拒绝覆盖已有安装"
            )
        }
        return try await install(force: false)
    }

    public func setDataProfileID(_ id: String?) {
        selectedDataProfileID = id
    }

    public func setRelease(_ release: RuntimeReleaseDescriptor) throws {
        guard release.architecture == architecture,
              RuntimeLocator.isSafeRuntimeVersion(release.runtimeVersion) else {
            throw RuntimeProvisioningError.unsupportedArchitecture(release.architecture)
        }
        guard !hasImmutableRuntimeVersionConflict(with: release) else {
            throw RuntimeProvisioningError.runtimeValidationFailed(
                "同一 Runtime 版本的内容不一致，拒绝覆盖已有安装"
            )
        }
        // A remote-only first launch starts with the legacy placeholder path
        // before the catalog has been resolved. Once a verified release is
        // known, place a missing installation in its versioned directory so
        // the first provisioned Runtime follows the same layout as bundled
        // catalog installations.
        if !fileManager.fileExists(atPath: root.path) {
            if root.lastPathComponent == "Runtime",
               let versionedRoot = RuntimeLocator.versionedRuntimeRoot(
                   supportDirectory: root.deletingLastPathComponent(),
                   runtimeVersion: release.runtimeVersion
               ) {
                root = versionedRoot
            } else if let supportDirectory = versionedSupportDirectory,
                      let versionedRoot = RuntimeLocator.versionedRuntimeRoot(
                          supportDirectory: supportDirectory,
                          runtimeVersion: release.runtimeVersion
                      ) {
                // An active-state pointer may outlive a deleted versioned
                // directory. Do not install a newer release into the old
                // version's path.
                root = versionedRoot
            }
        }
        self.release = release
    }

    public func prepareUpdate() async throws -> RuntimeProvisioningResult {
        guard !hasImmutableRuntimeVersionConflict(with: release) else {
            throw RuntimeProvisioningError.runtimeValidationFailed(
                "同一 Runtime 版本的内容不一致，拒绝覆盖已有安装"
            )
        }
        let candidate = RuntimeLocator.candidateRoot(root: root, runtimeVersion: release.runtimeVersion)
        if let manifest = RuntimeLocator.installationManifest(root: candidate),
           manifest.matches(release),
           RuntimeLocator.isCompleteInstallation(
               root: candidate,
               architecture: architecture,
               fileManager: fileManager
           ) {
            return RuntimeProvisioningResult(root: candidate, architecture: architecture, manifest: manifest)
        }
        return try await install(force: true, destinationRoot: candidate)
    }

    public func activatePreparedUpdate() throws -> RuntimeProvisioningResult {
        guard !hasImmutableRuntimeVersionConflict(with: release) else {
            throw RuntimeProvisioningError.runtimeValidationFailed(
                "同一 Runtime 版本的内容不一致，拒绝覆盖已有安装"
            )
        }
        let candidate = RuntimeLocator.candidateRoot(root: root, runtimeVersion: release.runtimeVersion)
        guard let manifest = RuntimeLocator.installationManifest(root: candidate),
              manifest.matches(release),
              RuntimeLocator.isCompleteInstallation(
                  root: candidate,
                  architecture: architecture,
                  fileManager: fileManager
              ) else {
            throw RuntimeProvisioningError.runtimeValidationFailed("没有可激活的已验证 Runtime 更新")
        }
        if versionedSupportDirectory != nil,
           RuntimeLocator.isVersionedRuntimeRoot(root, supportDirectory: versionedSupportDirectory!) {
            // Versioned installations already live at their final path. The
            // activation boundary is the RuntimeProvisioner root pointer; the
            // durable active-state is written only after the new process is healthy.
            self.root = candidate
            return try existingResult()
        }
        try publish(staging: candidate)
        return try existingResult()
    }

    public func update() async throws -> RuntimeProvisioningResult {
        _ = try await prepareUpdate()
        return try activatePreparedUpdate()
    }

    private func install(
        force: Bool,
        destinationRoot: URL? = nil
    ) async throws -> RuntimeProvisioningResult {
        if release.artifact != nil {
            return try await installArtifact(force: force, destinationRoot: destinationRoot)
        }
#if DEBUG
        // The legacy path remains available only for local development while
        // a release artifact is being built. Production apps must ship a
        // catalog entry and never install npm dependencies on the user Mac.
        return try await installLegacy(force: force, destinationRoot: destinationRoot)
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
