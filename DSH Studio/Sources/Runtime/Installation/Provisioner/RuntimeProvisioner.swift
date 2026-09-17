//
//  RuntimeProvisioner.swift
//  DSH Studio
//

import CryptoKit
import Foundation

/// Downloads and installs the fixed Node and Harness dependency graph.
///
/// A complete installation is published only after every file has been verified,
/// so an interrupted first launch cannot be mistaken for a usable Runtime.
public final class RuntimeProvisioner: RuntimeCandidateUpdating, RuntimeDataProfileSelecting, RuntimeReleaseUpdating, @unchecked Sendable {
    public internal(set) var root: URL
    /// Architecture this provisioner installs and validates.
    public let architecture: String
    public private(set) var release: RuntimeReleaseDescriptor
    /// Store used to read the active data profile, when one is configured.
    public let dataProfileStore: RuntimeDataProfileStore?
    private var selectedDataProfileID: String?

    /// Identifier of the data profile an update will reuse.
    ///
    /// An explicitly selected id wins; otherwise the durable active profile is used.
    public var dataProfileID: String? {
        selectedDataProfileID ?? dataProfileStore?.activeState()?.profileID
    }

    /// File system seam used by tests.
    let fileManager: FileManager
    /// Bundle that provides the packaged dependency lockfile.
    let bundle: Bundle
    /// Download seam for Node and Runtime artifacts.
    let downloader: any RuntimeAssetDownloading
    /// Command seam for `tar` and `npm` during installation.
    let commandRunner: any RuntimeCommandRunning
    /// Dependency lockfile override; `nil` uses the file packaged in ``bundle``.
    let packageLockDataOverride: Data?
    /// Node checksum override used by tests; `nil` uses the pinned release value.
    let nodeArchiveSHA256Override: String?

    /// Creates a provisioner for one installation root.
    ///
    /// The release defaults to the pinned descriptor for the architecture, with the
    /// architecture and Node checksum taken from the bundled catalog.
    ///
    /// - Parameters:
    ///   - root: Installation root this provisioner owns.
    ///   - architecture: Architecture to install; defaults to this host's.
    ///   - bundle: Bundle providing the packaged dependency lockfile.
    ///   - fileManager: File system seam used by tests.
    ///   - downloader: Download seam; defaults to `URLSession`.
    ///   - commandRunner: Command seam; defaults to the system runner.
    ///   - packageLockData: Lockfile bytes overriding the packaged file.
    ///   - nodeArchiveSHA256Override: Node checksum overriding the pinned release.
    ///   - release: Release to install; defaults to the app's pinned release.
    ///   - dataProfileStore: Store used to read the active data profile.
    ///   - dataProfileID: Explicitly selected data profile identifier.
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

    /// Installs the pinned Runtime when it is missing or invalid.
    ///
    /// An existing installation of the same version is never overwritten when its
    /// content differs, because the version string is immutable by contract.
    ///
    /// - Returns: The installed root, architecture, and manifest.
    /// - Throws: ``RuntimeProvisioningError`` when the content conflicts, a download
    ///   or command fails, or the installation does not validate.
    public func provision() async throws -> RuntimeProvisioningResult {
        guard !hasImmutableRuntimeVersionConflict(with: release) else {
            throw RuntimeProvisioningError.runtimeValidationFailed(
                "同一 Runtime 版本的内容不一致，拒绝覆盖已有安装"
            )
        }
        return try await install(force: false)
    }

    /// Selects the data profile an update should reuse.
    ///
    /// - Parameter id: Profile identifier, or `nil` to fall back to the active profile.
    public func setDataProfileID(_ id: String?) {
        selectedDataProfileID = id
    }

    /// Changes the release this provisioner installs.
    ///
    /// Also relocates a not-yet-installed root into its versioned directory, so a
    /// remote-only first launch ends up in the same layout as a bundled catalog
    /// installation.
    ///
    /// - Parameter release: Verified release to install next.
    /// - Throws: ``RuntimeProvisioningError`` when the architecture or version is
    ///   unusable, or when the version already exists with different content.
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

    /// Downloads and verifies the candidate without activating it.
    ///
    /// The active Runtime keeps running; activation is a separate call.
    ///
    /// - Returns: The prepared candidate.
    /// - Throws: ``RuntimeProvisioningError`` when the artifact is unavailable,
    ///   a download or command fails, or the candidate does not validate.
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

    /// Activates the prepared candidate, replacing the active Runtime.
    ///
    /// - Returns: The activated root, architecture, and manifest.
    /// - Throws: ``RuntimeProvisioningError`` when nothing was prepared or the
    ///   activation cannot complete.
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

    /// Prepares and activates the pinned release in one step.
    ///
    /// - Returns: The activated root, architecture, and manifest.
    /// - Throws: ``RuntimeProvisioningError`` when preparation, activation, or
    ///   validation fails.
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

    /// Builds a result for the installation already present at ``root``.
    ///
    /// - Returns: The root, architecture, and manifest read from disk.
    /// - Throws: ``RuntimeProvisioningError/installationFailed(_:)`` when the
    ///   manifest is missing or unreadable.
    func existingResult() throws -> RuntimeProvisioningResult {
        let url = RuntimeLocator.runtimeManifestURL(root: root)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(RuntimeInstallationManifest.self, from: data) else {
            throw RuntimeProvisioningError.installationFailed("已存在的 Runtime manifest 无法读取")
        }
        return RuntimeProvisioningResult(root: root, architecture: architecture, manifest: manifest)
    }

    /// Creates a directory, mapping file system failures onto provisioning errors.
    ///
    /// - Parameter url: Directory to create, including intermediate directories.
    /// - Throws: ``RuntimeProvisioningError/installationFailed(_:)``.
    func createDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw RuntimeProvisioningError.installationFailed(error.localizedDescription)
        }
    }

    /// Computes the SHA-256 digest of a file.
    ///
    /// - Parameter url: File to hash; it is memory-mapped rather than copied.
    /// - Returns: Lowercase hexadecimal digest.
    /// - Throws: ``RuntimeProvisioningError/downloadFailed(_:)`` when the file cannot
    ///   be read.
    func sha256(at url: URL) throws -> String {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        } catch {
            throw RuntimeProvisioningError.downloadFailed(error.localizedDescription)
        }
    }

    /// Restores the executable bit on the `node-pty` spawn helper.
    ///
    /// Archive extraction drops the permission, and the Harness terminal needs it to
    /// spawn processes.
    ///
    /// - Parameter harnessRoot: Harness root that contains `node_modules`.
    /// - Throws: ``RuntimeProvisioningError/installationFailed(_:)`` when the
    ///   permission cannot be set.
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

    /// Verifies the native `node-pty` dependency is usable.
    ///
    /// - Parameter harnessRoot: Harness root that contains `node_modules`.
    /// - Throws: ``RuntimeProvisioningError/runtimeValidationFailed(_:)`` when the
    ///   prebuilt binary or its executable helper is missing.
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

    /// Builds the isolated environment used for setup commands.
    ///
    /// The `PATH` starts with the bundled Node directory and npm is configured to
    /// skip scripts, audit, funding, and update notices, so installation never
    /// reaches outside the verified dependency graph.
    ///
    /// - Parameter nodeRoot: Node installation that must come first on `PATH`.
    /// - Returns: Environment variables for the child command.
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

    /// Trims command output for error messages.
    ///
    /// - Parameter text: Raw command output.
    /// - Returns: The trimmed text, capped at the last 1 500 characters so the tail
    ///   of a failure is what reaches the user.
    func summarize(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 1_500 else { return clean }
        return String(clean.suffix(1_500))
    }
}
