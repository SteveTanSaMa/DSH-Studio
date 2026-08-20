//
//  RuntimeProvisionerInstallation.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import Foundation

/// Installation paths for the development compatibility setup and the
/// immutable artifact setup live here so the provisioner entry point remains
/// focused on selecting the correct strategy.
extension RuntimeProvisioner {
    /// Compatibility path for local development builds that have not yet
    /// received a published artifact catalog.
    func installLegacy(force: Bool) async throws -> RuntimeProvisioningResult {
        // Work happens in an isolated staging directory and is published only
        // after checksum, Node, npm, Harness, and native dependency checks.
        guard RuntimeRelease.nodeArchiveURL(
            nodeVersion: release.nodeVersion,
            architecture: architecture
        ) != nil else {
            throw RuntimeProvisioningError.unsupportedArchitecture(architecture)
        }
        if !force && RuntimeLocator.isComplete(
            root: root,
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

        let packageLockData = try loadPackageLockData()
        do {
            try RuntimePackageLockValidator.validate(
                data: packageLockData,
                expectedHarnessVersion: release.harnessVersion,
                expectedHarnessIntegrity: release.harnessPackageIntegrity,
                expectedPnpmVersion: release.pnpmVersion,
                expectedPnpmIntegrity: release.pnpmPackageIntegrity
            )
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
        guard let archiveURL = RuntimeRelease.nodeArchiveURL(
            nodeVersion: release.nodeVersion,
            architecture: architecture
        ) else {
            throw RuntimeProvisioningError.unsupportedArchitecture(architecture)
        }
        try await downloader.download(from: archiveURL, to: archive)
        let actualSHA256 = try sha256(at: archive)
        guard actualSHA256 == release.nodeArchiveSHA256 else {
            throw RuntimeProvisioningError.checksumMismatch(
                expected: release.nodeArchiveSHA256,
                actual: actualSHA256
            )
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
              RuntimeLocator.nodeVersion(nodeExecutable: nodeExecutable) == release.nodeVersion else {
            throw RuntimeProvisioningError.runtimeValidationFailed("Node 版本或可执行文件无效")
        }

        let harnessRoot = RuntimeLocator.harnessRoot(
            root: staging,
            architecture: architecture,
            harnessVersion: release.harnessVersion
        )
        try createDirectory(harnessRoot)
        try RuntimeRelease.packageJSONData(
            harnessVersion: release.harnessVersion,
            pnpmVersion: release.pnpmVersion
        )
            .write(to: harnessRoot.appendingPathComponent("package.json"), options: .atomic)
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
        let harnessEntry = RuntimeLocator.harnessEntry(
            root: staging,
            architecture: architecture,
            harnessVersion: release.harnessVersion
        )
        guard fileManager.fileExists(atPath: harnessEntry.path),
              RuntimeLocator.packageJSONVersion(at: harnessEntry) == release.harnessVersion else {
            throw RuntimeProvisioningError.runtimeValidationFailed("Harness 包入口或版本无效")
        }
        let pnpmExecutable = RuntimeLocator.pnpmExecutable(
            root: staging,
            architecture: architecture,
            harnessVersion: release.harnessVersion
        )
        guard fileManager.isExecutableFile(atPath: pnpmExecutable.path),
              RuntimeLocator.packageJSONVersion(
                  atPackageURL: RuntimeLocator.pnpmPackageJSON(
                      root: staging,
                      architecture: architecture,
                      harnessVersion: release.harnessVersion
                  )
              ) == release.pnpmVersion else {
            throw RuntimeProvisioningError.runtimeValidationFailed("Runtime 缺少受信任的 pnpm")
        }
        try validateNativeDependencies(in: harnessRoot)

        let manifest = RuntimeInstallationManifest(
            architecture: architecture,
            nodeVersion: release.nodeVersion,
            harnessVersion: release.harnessVersion,
            pnpmVersion: release.pnpmVersion,
            nodeSHA256: release.nodeArchiveSHA256,
            harnessPackageIntegrity: release.harnessPackageIntegrity,
            pnpmPackageIntegrity: release.pnpmPackageIntegrity
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: RuntimeLocator.runtimeManifestURL(root: staging), options: .atomic)
        try fileManager.removeItem(at: archive)
        try publish(staging: staging)
        return RuntimeProvisioningResult(root: root, architecture: architecture, manifest: manifest)
    }

    func installArtifact(force: Bool) async throws -> RuntimeProvisioningResult {
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
        if !force,
           RuntimeLocator.isComplete(
               root: root,
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

        let parent = root.deletingLastPathComponent()
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
        try publish(staging: staging)
        return RuntimeProvisioningResult(root: root, architecture: architecture, manifest: manifest)
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
