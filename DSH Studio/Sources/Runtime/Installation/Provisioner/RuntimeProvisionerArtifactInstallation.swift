//
//  RuntimeProvisionerArtifactInstallation.swift
//  DSH Studio
//

import Foundation

/// Installs a Runtime from the verified artifact the app ships with.
extension RuntimeProvisioner {
    /// Verifies the pinned artifact and installs it into the given root.
    ///
    /// The artifact description must be complete for this architecture and version,
    /// and a trusted URL plus a 64-character hex digest are required before anything
    /// is downloaded. An already-complete installation is reused unless `force` is set.
    ///
    /// - Parameters:
    ///   - force: Reinstalls even when the destination already validates.
    ///   - destinationRoot: Root to install into; defaults to ``RuntimeProvisioner/root``.
    /// - Returns: The installed root, architecture, and manifest.
    /// - Throws: ``RuntimeProvisioningError`` when the description is incomplete, the
    ///   download or extraction fails, or the result does not validate.
    func installArtifact(
        force: Bool,
        destinationRoot: URL? = nil
    ) async throws -> RuntimeProvisioningResult {
        guard let artifact = release.artifact,
              artifact.architecture == architecture,
              artifact.runtimeVersion == release.runtimeVersion,
              RuntimeReleaseCatalog.isTrustedArtifactURL(
                  artifact.url,
                  runtimeVersion: release.runtimeVersion,
                  architecture: architecture
              ),
              artifact.sha256.count == 64,
              artifact.sha256.allSatisfy(\.isHexDigit) else {
            throw RuntimeProvisioningError.runtimeValidationFailed("Runtime artifact 描述不完整")
        }
        let destination = destinationRoot ?? root
        if !force,
           destination == root,
           RuntimeLocator.isComplete(
               root: destination,
               architecture: architecture,
               fileManager: fileManager,
               expectedNodeVersion: release.nodeVersion,
               expectedHarnessVersion: release.harnessVersion,
               expectedPnpmVersion: release.pnpmVersion,
               expectedNodeSHA256: release.nodeArchiveSHA256,
               expectedRelease: release
           ) {
            return try existingResult()
        }

        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".Runtime-\(UUID().uuidString)", isDirectory: true)
        try createDirectory(parent)
        try createDirectory(staging)
        defer {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
        }

        let archive = staging.appendingPathComponent("runtime.tar.gz", isDirectory: false)
        try await downloader.download(from: artifact.url, to: archive)
        let actualSHA256 = try sha256(at: archive)
        guard actualSHA256 == artifact.sha256 else {
            throw RuntimeProvisioningError.checksumMismatch(
                expected: artifact.sha256,
                actual: actualSHA256
            )
        }

        let listing = try commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-tzf", archive.path],
            currentDirectory: staging,
            environment: [:]
        )
        guard listing.status == 0 else {
            throw RuntimeProvisioningError.commandFailed(status: listing.status, detail: summarize(listing.stderr))
        }
        try RuntimeArchiveListingValidator.validate(listing.stdout)

        let extraction = try commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archive.path, "-C", staging.path],
            currentDirectory: staging,
            environment: [:]
        )
        guard extraction.status == 0 else {
            throw RuntimeProvisioningError.commandFailed(status: extraction.status, detail: summarize(extraction.stderr))
        }

        guard let manifest = RuntimeLocator.installationManifest(root: staging),
              manifest.matches(release),
              manifest.runtimeVersion == artifact.runtimeVersion else {
            throw RuntimeProvisioningError.runtimeValidationFailed("Runtime artifact manifest 与应用版本不一致")
        }
        try validateInstalledRuntime(root: staging, manifest: manifest)
        try fileManager.removeItem(at: archive)
        try publish(staging: staging, to: destination)
        return RuntimeProvisioningResult(root: destination, architecture: architecture, manifest: manifest)
    }

    private func validateInstalledRuntime(
        root: URL,
        manifest: RuntimeInstallationManifest
    ) throws {
        let node = RuntimeLocator.nodeExecutable(root: root, architecture: architecture)
        let harness = RuntimeLocator.harnessEntry(
            root: root,
            architecture: architecture,
            harnessVersion: manifest.harnessVersion
        )
        let pnpm = RuntimeLocator.pnpmExecutable(
            root: root,
            architecture: architecture,
            harnessVersion: manifest.harnessVersion
        )
        let nativeRoot = RuntimeLocator.harnessRoot(
            root: root,
            architecture: architecture,
            harnessVersion: manifest.harnessVersion
        )
            .appendingPathComponent("node_modules/node-pty/prebuilds/\(architecture)", isDirectory: true)
        guard fileManager.isExecutableFile(atPath: node.path),
              RuntimeLocator.nodeVersion(nodeExecutable: node) == manifest.nodeVersion,
              fileManager.fileExists(atPath: harness.path),
              RuntimeLocator.packageJSONVersion(at: harness) == manifest.harnessVersion,
              fileManager.isExecutableFile(atPath: pnpm.path),
              RuntimeLocator.packageJSONVersion(
                  atPackageURL: RuntimeLocator.pnpmPackageJSON(
                      root: root,
                      architecture: architecture,
                      harnessVersion: manifest.harnessVersion
                  )
              ) == manifest.pnpmVersion,
              fileManager.fileExists(atPath: nativeRoot.appendingPathComponent("pty.node").path),
              fileManager.isExecutableFile(atPath: nativeRoot.appendingPathComponent("spawn-helper").path) else {
            throw RuntimeProvisioningError.runtimeValidationFailed("Runtime artifact 内容不完整")
        }
    }
}
