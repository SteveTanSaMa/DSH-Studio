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

        let archive = try await obtainVerifiedArchive(staging: staging, artifact: artifact)
        reportStep("正在校验并解包 Runtime…")
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
        // A cached archive lives outside the staged tree and is kept for the next attempt;
        // one staged locally has to go before the tree is published.
        if archive.deletingLastPathComponent().standardizedFileURL == staging.standardizedFileURL {
            try fileManager.removeItem(at: archive)
        }
        try publish(staging: staging, to: destination)
        evictCachedArtifacts(except: artifact.sha256)
        return RuntimeProvisioningResult(root: destination, architecture: architecture, manifest: manifest)
    }

    /// Produces an archive whose bytes match the catalog entry for one artifact.
    ///
    /// The verified archive is reused when a previous attempt already downloaded and
    /// checked it, and an unfinished download is continued instead of restarted. Both are
    /// re-checked against the catalog's SHA-256 here, so a cached or partial file that does
    /// not match is discarded rather than trusted.
    ///
    /// - Parameters:
    ///   - staging: Staging directory the installation is assembled in.
    ///   - artifact: Artifact the catalog describes.
    /// - Returns: Path of the archive to extract, verified against the catalog.
    /// - Throws: ``RuntimeProvisioningError`` when the artifact cannot be obtained or the
    ///   downloaded bytes do not match the catalog checksum.
    private func obtainVerifiedArchive(
        staging: URL,
        artifact: RuntimeArtifactDescriptor
    ) async throws -> URL {
        if let downloadCacheDirectory {
            try? fileManager.createDirectory(at: downloadCacheDirectory, withIntermediateDirectories: true)
        }
        if let cached = cachedArchiveURL(for: artifact), fileManager.fileExists(atPath: cached.path) {
            reportStep("正在校验已下载的 Runtime…")
            if try sha256(at: cached) == artifact.sha256 {
                return cached
            }
            try? fileManager.removeItem(at: cached)
        }

        let archive = staging.appendingPathComponent("runtime.tar.gz", isDirectory: false)
        // The download is minutes long on a first launch, so the step names it and,
        // when the catalog published one, how large it is.
        let publishedSize = artifact.size.map {
            "（\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))）"
        } ?? ""
        let downloadDetail = "正在下载 Runtime\(publishedSize)…"
        report(RuntimeProvisioningProgress(fraction: 0, detail: downloadDetail))
        let partial = partialArchiveURL(for: artifact)
        do {
            try await downloader.download(from: artifact.url, to: archive, resumingFrom: partial) { [weak self] received, expected in
                self?.reportDownload(received: received, expected: expected, detail: downloadDetail)
            }
        } catch {
            // A transfer that could not be continued still leaves usable bytes behind: the
            // checksum decides whether they are the artifact, and anything else is dropped
            // so the next attempt starts from zero instead of building on debris.
            if let partial,
               fileManager.fileExists(atPath: partial.path),
               (try? sha256(at: partial)) == artifact.sha256 {
                try? fileManager.removeItem(at: archive)
                try? fileManager.moveItem(at: partial, to: archive)
            } else if let partial {
                try? fileManager.removeItem(at: partial)
                throw error
            } else {
                throw error
            }
        }

        let actualSHA256 = try sha256(at: archive)
        guard actualSHA256 == artifact.sha256 else {
            throw RuntimeProvisioningError.checksumMismatch(
                expected: artifact.sha256,
                actual: actualSHA256
            )
        }
        guard let cached = cachedArchiveURL(for: artifact) else { return archive }
        // Keeping the verified archive is what makes a retry after a later failure cheap.
        try? fileManager.removeItem(at: cached)
        do {
            try fileManager.moveItem(at: archive, to: cached)
            return cached
        } catch {
            // A cache that cannot be written is not worth failing the install for.
            return archive
        }
    }

    /// Path the verified archive is cached at, when a cache directory is configured.
    ///
    /// - Parameter artifact: Artifact the catalog describes.
    /// - Returns: Cache file, or `nil` when the caller did not configure a cache.
    private func cachedArchiveURL(for artifact: RuntimeArtifactDescriptor) -> URL? {
        downloadCacheDirectory?.appendingPathComponent("\(artifact.sha256).tar.gz", isDirectory: false)
    }

    /// Path an unfinished download is kept at, when a cache directory is configured.
    ///
    /// - Parameter artifact: Artifact the catalog describes.
    /// - Returns: Partial file, or `nil` when the caller did not configure a cache.
    private func partialArchiveURL(for artifact: RuntimeArtifactDescriptor) -> URL? {
        downloadCacheDirectory?.appendingPathComponent("\(artifact.sha256).partial", isDirectory: false)
    }

    /// Drops cached downloads that belong to other Runtime builds.
    ///
    /// - Parameter sha256: Checksum of the artifact this install just published.
    private func evictCachedArtifacts(except sha256: String) {
        guard let downloadCacheDirectory,
              let entries = try? fileManager.contentsOfDirectory(atPath: downloadCacheDirectory.path) else {
            return
        }
        for entry in entries where !entry.hasPrefix(sha256) {
            try? fileManager.removeItem(at: downloadCacheDirectory.appendingPathComponent(entry))
        }
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
