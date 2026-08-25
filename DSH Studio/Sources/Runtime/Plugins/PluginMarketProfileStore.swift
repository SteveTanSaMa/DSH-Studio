//
//  PluginMarketProfileStore.swift
//  DSH Studio
//

import Foundation

public struct PluginMarketProfileInspection: Equatable, Sendable {
    public let profileDirectory: URL
    public let dependencySpec: String?
    public let installedVersion: String?
    public let packageJSONPresent: Bool
    public let packageManifestValid: Bool
    public let bundleListed: Bool
    public let bundlePatchValid: Bool
    public let entryPointValid: Bool
    public let lockIntegrityValid: Bool
    public let enabled: Bool

    public init(
        profileDirectory: URL,
        dependencySpec: String?,
        installedVersion: String?,
        packageJSONPresent: Bool,
        packageManifestValid: Bool,
        bundleListed: Bool,
        bundlePatchValid: Bool,
        entryPointValid: Bool,
        lockIntegrityValid: Bool,
        enabled: Bool
    ) {
        self.profileDirectory = profileDirectory
        self.dependencySpec = dependencySpec
        self.installedVersion = installedVersion
        self.packageJSONPresent = packageJSONPresent
        self.packageManifestValid = packageManifestValid
        self.bundleListed = bundleListed
        self.bundlePatchValid = bundlePatchValid
        self.entryPointValid = entryPointValid
        self.lockIntegrityValid = lockIntegrityValid
        self.enabled = enabled
    }
}

public struct PluginMarketProfileSnapshot: Sendable {
    fileprivate let files: [String: Data?]
    fileprivate let packageName: String?
    fileprivate let packageRoot: String?
    fileprivate let packageLinkDestination: String?
    fileprivate let packageFiles: [String: Data]
    fileprivate let packageLinks: [String: String]

    fileprivate init(
        files: [String: Data?],
        packageName: String?,
        packageRoot: String?,
        packageLinkDestination: String?,
        packageFiles: [String: Data],
        packageLinks: [String: String]
    ) {
        self.files = files
        self.packageName = packageName
        self.packageRoot = packageRoot
        self.packageLinkDestination = packageLinkDestination
        self.packageFiles = packageFiles
        self.packageLinks = packageLinks
    }
}

/// Owns only the fixed `DSH_HOME/profiles/web` contract used by dsh-market.
/// It rejects symlinks that resolve outside the managed Profile and edits one
/// narrowly-scoped patch entry rather than treating YAML as a command surface.
public final class PluginMarketProfileStore: @unchecked Sendable {
    public let dshHome: URL
    public let profileName: String
    public let profileDirectory: URL

    private let fileManager: FileManager
    private let patchFileName = "cordis.patch.yml"
    private let packageFileName = "package.json"
    private let snapshotFileNames = [
        "package.json",
        "pnpm-lock.yaml",
        "pnpm-workspace.yaml",
        "cordis.patch.yml",
        ".dsh-market/state.json",
    ]

    public init(
        dshHome: URL,
        profileName: String = PluginMarketRelease.profileName,
        fileManager: FileManager = .default
    ) {
        self.dshHome = dshHome.standardizedFileURL
        self.profileName = profileName
        self.profileDirectory = self.dshHome
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(profileName, isDirectory: true)
        self.fileManager = fileManager
    }

    public func validatePath() throws {
        guard Self.isSafeProfileName(profileName) else {
            throw PluginMarketManagerError.unsafeProfile("Profile 名称无效")
        }
        let root = dshHome.standardizedFileURL
        let profile = profileDirectory.standardizedFileURL
        guard profile.path == root.path || profile.path.hasPrefix(root.path + "/") else {
            throw PluginMarketManagerError.unsafeProfile("Profile 路径逃逸 DSH_HOME")
        }

        try validateExistingComponents(from: root, through: profile)
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedProfile = profile.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedProfile.path == resolvedRoot.path
                || resolvedProfile.path.hasPrefix(resolvedRoot.path + "/") else {
            throw PluginMarketManagerError.unsafeProfile("Profile 真实路径逃逸 DSH_HOME")
        }
    }

    public func ensureProfileDirectory() throws {
        try validatePath()
        try fileManager.createDirectory(
            at: profileDirectory,
            withIntermediateDirectories: true
        )
        try validatePath()
    }

    public func inspect() throws -> PluginMarketProfileInspection {
        try validatePath()
        guard fileManager.fileExists(atPath: profileDirectory.path) else {
            return PluginMarketProfileInspection(
                profileDirectory: profileDirectory,
                dependencySpec: nil,
                installedVersion: nil,
                packageJSONPresent: false,
                packageManifestValid: false,
                bundleListed: false,
                bundlePatchValid: false,
                entryPointValid: false,
                lockIntegrityValid: false,
                enabled: true
            )
        }

        let packageURL = try safeFileURL(packageFileName)
        guard let packageData = try? Data(contentsOf: packageURL) else {
            return PluginMarketProfileInspection(
                profileDirectory: profileDirectory,
                dependencySpec: nil,
                installedVersion: nil,
                packageJSONPresent: fileManager.fileExists(atPath: packageURL.path),
                packageManifestValid: false,
                bundleListed: false,
                bundlePatchValid: false,
                entryPointValid: false,
                lockIntegrityValid: false,
                enabled: try isMarketEnabled()
            )
        }
        guard let object = try? JSONSerialization.jsonObject(with: packageData),
              let manifest = object as? [String: Any] else {
            return PluginMarketProfileInspection(
                profileDirectory: profileDirectory,
                dependencySpec: nil,
                installedVersion: nil,
                packageJSONPresent: true,
                packageManifestValid: false,
                bundleListed: false,
                bundlePatchValid: false,
                entryPointValid: false,
                lockIntegrityValid: false,
                enabled: try isMarketEnabled()
            )
        }
        let dependencies = manifest["dependencies"] as? [String: Any] ?? [:]
        let dependencySpec = (dependencies[PluginMarketRelease.packageName] as? String)
            ?? (dependencies["dsh-market"] as? String)
        let bundleListed = profileBundles(in: manifest).contains { Self.isMarketName($0) }

        guard let dependencySpec else {
            return PluginMarketProfileInspection(
                profileDirectory: profileDirectory,
                dependencySpec: nil,
                installedVersion: nil,
                packageJSONPresent: true,
                packageManifestValid: true,
                bundleListed: bundleListed,
                bundlePatchValid: false,
                entryPointValid: false,
                lockIntegrityValid: false,
                enabled: try isMarketEnabled()
            )
        }

        let installedPackageName = dependencies[PluginMarketRelease.packageName] != nil
            ? PluginMarketRelease.packageName
            : "dsh-market"
        let packageDirectory = try safeDirectoryURL(
            "node_modules/\(installedPackageName)",
            allowMissing: true
        )
        guard let packageDirectory,
              let installedManifestURL = try? safeFileURL(
                  "node_modules/\(installedPackageName)/package.json"
              ),
              let installedData = try? Data(contentsOf: installedManifestURL),
              let installedObject = try? JSONSerialization.jsonObject(with: installedData),
              let installedManifest = installedObject as? [String: Any],
              packageDirectory.path.hasPrefix(profileDirectory.path + "/") else {
            return PluginMarketProfileInspection(
                profileDirectory: profileDirectory,
                dependencySpec: dependencySpec,
                installedVersion: nil,
                packageJSONPresent: true,
                packageManifestValid: false,
                bundleListed: bundleListed,
                bundlePatchValid: false,
                entryPointValid: false,
                lockIntegrityValid: (try? hasExpectedLockIntegrity()) == true,
                enabled: try isMarketEnabled()
            )
        }

        let installedName = installedManifest["name"] as? String
        let installedVersion = installedManifest["version"] as? String
        let valid = (installedName == PluginMarketRelease.packageName
            || installedName == "dsh-market")
            && installedVersion != nil
        let bundlePatchValid = Self.hasExpectedBundlePatch(
            in: installedManifest,
            packageDirectory: packageDirectory,
            fileManager: fileManager
        )
        let entryPointValid = Self.hasExpectedEntryPoint(
            in: installedManifest,
            packageDirectory: packageDirectory,
            fileManager: fileManager
        )

        return PluginMarketProfileInspection(
            profileDirectory: profileDirectory,
            dependencySpec: dependencySpec,
            installedVersion: installedVersion,
            packageJSONPresent: true,
            packageManifestValid: valid,
            bundleListed: bundleListed,
            bundlePatchValid: bundlePatchValid,
            entryPointValid: entryPointValid,
            lockIntegrityValid: (try? hasExpectedLockIntegrity()) == true,
            enabled: try isMarketEnabled()
        )
    }

    public func snapshot() throws -> PluginMarketProfileSnapshot {
        try validatePath()
        var files: [String: Data?] = [:]
        for name in snapshotFileNames {
            let url = try safeFileURL(name)
            files[name] = fileManager.fileExists(atPath: url.path)
                ? try Data(contentsOf: url)
                : nil
        }
        let package = try snapshotMarketPackage()
        return PluginMarketProfileSnapshot(
            files: files,
            packageName: package.name,
            packageRoot: package.root,
            packageLinkDestination: package.linkDestination,
            packageFiles: package.files,
            packageLinks: package.links
        )
    }

    public func hasExpectedLockIntegrity() throws -> Bool {
        try validatePath()
        let url = try safeFileURL("pnpm-lock.yaml")
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let data = try Data(contentsOf: url)
        guard data.count <= 4 * 1024 * 1024 else {
            throw PluginMarketManagerError.malformedProfile("pnpm-lock.yaml 过大")
        }
        let text = String(decoding: data, as: UTF8.self)
        let packageReference = text.contains("dshmarket@\(PluginMarketRelease.packageVersion)")
            || text.contains("dsh-market@\(PluginMarketRelease.packageVersion)")
        return packageReference
            && text.contains(PluginMarketRelease.packageIntegrity)
    }

    public func validateExpectedInstallation() throws -> PluginMarketProfileInspection {
        let inspection = try inspect()
        guard inspection.dependencySpec == PluginMarketRelease.packageVersion else {
            throw PluginMarketManagerError.malformedProfile(
                "package.json 未锁定到 dshmarket@\(PluginMarketRelease.packageVersion)"
            )
        }
        guard inspection.packageManifestValid,
              inspection.installedVersion == PluginMarketRelease.packageVersion else {
            throw PluginMarketManagerError.malformedProfile(
                "node_modules 中的 dshmarket package.json 版本无效"
            )
        }
        guard try hasExpectedLockIntegrity() else {
            throw PluginMarketManagerError.malformedProfile(
                "pnpm-lock.yaml 缺少 dshmarket 的固定 integrity"
            )
        }
        guard inspection.bundleListed else {
            throw PluginMarketManagerError.malformedProfile(
                "package.json 的 dsh.profile.bundles 缺少 dshmarket"
            )
        }
        guard inspection.bundlePatchValid else {
            throw PluginMarketManagerError.malformedProfile(
                "dshmarket 未声明固定的 cordis.patch.yml bundle"
            )
        }
        guard inspection.entryPointValid else {
            throw PluginMarketManagerError.malformedProfile(
                "dshmarket 缺少 lib/index.js 入口"
            )
        }
        return inspection
    }

    public func validateMarketAbsent() throws {
        let inspection = try inspect()
        guard inspection.dependencySpec == nil else {
            throw PluginMarketManagerError.malformedProfile(
                "卸载后 package.json 仍包含 Plugin Market"
            )
        }
        guard !inspection.bundleListed else {
            throw PluginMarketManagerError.malformedProfile(
                "卸载后 package.json 仍注册 Plugin Market bundle"
            )
        }

        let patchURL = try safeFileURL(patchFileName)
        if fileManager.fileExists(atPath: patchURL.path) {
            let data = try Data(contentsOf: patchURL)
            guard data.count <= 256 * 1024 else {
                throw PluginMarketManagerError.malformedProfile("cordis.patch.yml 过大")
            }
            let marketBlocks = try patchBlocks(in: String(decoding: data, as: UTF8.self))
                .filter(\.isMarket)
            guard marketBlocks.isEmpty else {
                throw PluginMarketManagerError.malformedProfile(
                    "卸载后 cordis.patch.yml 仍包含 Plugin Market 条目"
                )
            }
        }

        try validateManagedPackageAbsent()
    }

    public func restore(_ snapshot: PluginMarketProfileSnapshot) throws {
        try ensureProfileDirectory()
        try removeManagedPackageMaterialization()
        if let packageRoot = snapshot.packageRoot {
            let rootURL = try safeFileURL(packageRoot)
            if fileManager.fileExists(atPath: rootURL.path) {
                try fileManager.removeItem(at: rootURL)
            }
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            for (relativePath, data) in snapshot.packageFiles {
                let fileURL = try safeFileURL("\(packageRoot)/\(relativePath)")
                try fileManager.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: fileURL, options: .atomic)
            }
            for (relativePath, destination) in snapshot.packageLinks {
                let linkURL = try safeFileURL("\(packageRoot)/\(relativePath)")
                try fileManager.createDirectory(
                    at: linkURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.createSymbolicLink(
                    atPath: linkURL.path,
                    withDestinationPath: destination
                )
            }
            if let packageName = snapshot.packageName,
               let packageLinkDestination = snapshot.packageLinkDestination {
                let packageURL = try safeFileURL("node_modules/\(packageName)")
                try fileManager.createDirectory(
                    at: packageURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.createSymbolicLink(
                    atPath: packageURL.path,
                    withDestinationPath: packageLinkDestination
                )
            }
        }
        for name in snapshotFileNames {
            let url = try safeFileURL(name)
            guard let data = snapshot.files[name] ?? nil else {
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
                continue
            }
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
    }

    private struct MarketPackageSnapshot {
        let name: String?
        let root: String?
        let linkDestination: String?
        let files: [String: Data]
        let links: [String: String]
    }

    private func snapshotMarketPackage() throws -> MarketPackageSnapshot {
        let packageURL = try safeFileURL(packageFileName)
        guard let data = try? Data(contentsOf: packageURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let manifest = object as? [String: Any],
              let dependencies = manifest["dependencies"] as? [String: Any] else {
            return MarketPackageSnapshot(
                name: nil,
                root: nil,
                linkDestination: nil,
                files: [:],
                links: [:]
            )
        }
        let name = [PluginMarketRelease.packageName, "dsh-market"]
            .first { dependencies[$0] != nil }
        guard let name else {
            return MarketPackageSnapshot(
                name: nil,
                root: nil,
                linkDestination: nil,
                files: [:],
                links: [:]
            )
        }
        let packageDirectoryURL = try safeDirectoryURL("node_modules/\(name)", allowMissing: true)
        guard let packageDirectoryURL else {
            return MarketPackageSnapshot(
                name: name,
                root: nil,
                linkDestination: nil,
                files: [:],
                links: [:]
            )
        }
        let packageLinkDestination: String?
        if let type = try fileManager.attributesOfItem(atPath: packageDirectoryURL.path)[.type] as? FileAttributeType,
           type == .typeSymbolicLink {
            packageLinkDestination = try fileManager.destinationOfSymbolicLink(atPath: packageDirectoryURL.path)
        } else {
            packageLinkDestination = nil
        }
        let resolvedPackageURL = packageDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        let profileRoot = profileDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedPackageURL.path.hasPrefix(profileRoot.path + "/") else {
            throw PluginMarketManagerError.unsafeProfile("dshmarket 包目录逃逸 Profile")
        }
        let rootRelativePath = String(resolvedPackageURL.path.dropFirst(profileRoot.path.count + 1))
        var files: [String: Data] = [:]
        var links: [String: String] = [:]
        var totalBytes = 0
        guard let enumerator = fileManager.enumerator(
            at: resolvedPackageURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw PluginMarketManagerError.malformedProfile("无法读取 dshmarket 包目录")
        }
        for case let itemURL as URL in enumerator {
            let resolvedItemURL = itemURL.resolvingSymlinksInPath().standardizedFileURL
            let relative = String(resolvedItemURL.path.dropFirst(resolvedPackageURL.path.count + 1))
            let attributes = try fileManager.attributesOfItem(atPath: itemURL.path)
            if let type = attributes[.type] as? FileAttributeType,
               type == .typeSymbolicLink {
                let destination = try fileManager.destinationOfSymbolicLink(atPath: itemURL.path)
                let resolvedLink = resolvedItemURL
                guard resolvedLink.path.hasPrefix(profileRoot.path + "/") else {
                    throw PluginMarketManagerError.unsafeProfile("dshmarket 包内链接逃逸 Profile：\(relative)")
                }
                links[relative] = destination
                continue
            }
            let values = try resolvedItemURL.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true { continue }
            let fileData = try Data(contentsOf: resolvedItemURL)
            guard fileData.count <= 16 * 1024 * 1024,
                  totalBytes + fileData.count <= 64 * 1024 * 1024 else {
                throw PluginMarketManagerError.malformedProfile("dshmarket 包快照过大")
            }
            files[relative] = fileData
            totalBytes += fileData.count
        }
        return MarketPackageSnapshot(
            name: name,
            root: rootRelativePath,
            linkDestination: packageLinkDestination,
            files: files,
            links: links
        )
    }

    private func removeManagedPackageMaterialization() throws {
        for name in [PluginMarketRelease.packageName, "dsh-market"] {
            let url = try safeFileURL("node_modules/\(name)")
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }

        guard let pnpmDirectory = try safeDirectoryURL("node_modules/.pnpm", allowMissing: true),
              let entries = try? fileManager.contentsOfDirectory(atPath: pnpmDirectory.path) else {
            return
        }
        for entry in entries where Self.isManagedPnpmEntry(entry) {
            let entryURL = pnpmDirectory.appendingPathComponent(entry, isDirectory: true)
            try rejectSymlinkIfPresent(entryURL, containedBy: profileDirectory)
            if fileManager.fileExists(atPath: entryURL.path) {
                try fileManager.removeItem(at: entryURL)
            }
        }
    }

    private func validateManagedPackageAbsent() throws {
        for name in [PluginMarketRelease.packageName, "dsh-market"] {
            let url = try safeFileURL("node_modules/\(name)")
            guard !fileManager.fileExists(atPath: url.path) else {
                throw PluginMarketManagerError.malformedProfile(
                    "卸载后仍残留 node_modules/\(name)"
                )
            }
        }

        guard let pnpmDirectory = try safeDirectoryURL("node_modules/.pnpm", allowMissing: true),
              let entries = try? fileManager.contentsOfDirectory(atPath: pnpmDirectory.path) else {
            return
        }
        if let entry = entries.first(where: Self.isManagedPnpmEntry) {
            throw PluginMarketManagerError.malformedProfile(
                "卸载后仍残留 node_modules/.pnpm/\(entry)"
            )
        }
    }

    private static func isManagedPnpmEntry(_ name: String) -> Bool {
        name == PluginMarketRelease.packageName
            || name.hasPrefix(PluginMarketRelease.packageName + "@")
            || name == "dsh-market"
            || name.hasPrefix("dsh-market@")
    }

    public func isMarketEnabled() throws -> Bool {
        try validatePath()
        let url = try safeFileURL(patchFileName)
        guard fileManager.fileExists(atPath: url.path) else { return true }
        let data = try Data(contentsOf: url)
        guard data.count <= 256 * 1024 else {
            throw PluginMarketManagerError.malformedProfile("cordis.patch.yml 过大")
        }
        return try patchBlocks(in: String(decoding: data, as: UTF8.self))
            .first(where: { $0.isMarket })?.disabled != true
    }

    public func setMarketEnabled(_ enabled: Bool) throws {
        try ensureProfileDirectory()
        let url = try safeFileURL(patchFileName)
        let existing: String
        if fileManager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard data.count <= 256 * 1024 else {
                throw PluginMarketManagerError.malformedProfile("cordis.patch.yml 过大")
            }
            existing = String(decoding: data, as: UTF8.self)
        } else {
            existing = ""
        }

        var lines = existing.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let blocks = try patchBlocks(in: existing)
        let marketBlocks = blocks.filter(\.isMarket)
        guard marketBlocks.count <= 1 else {
            throw PluginMarketManagerError.malformedProfile("Plugin Market 补丁条目重复")
        }

        if let block = marketBlocks.first {
            var replaced = false
            for index in block.start..<block.end {
                let line = lines[index]
                if line.range(of: #"^(\s*)disabled:\s*(true|false)(\s*(#.*))?$"#, options: .regularExpression) != nil {
                    let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
                    let comment = line.firstIndex(of: "#").map { String(line[$0...]) } ?? ""
                    lines[index] = "\(indentation)disabled: \(enabled ? "false" : "true")\(comment.isEmpty ? "" : " \(comment)")"
                    replaced = true
                    break
                }
            }
            if !replaced {
                let insertAt = min(block.start + 1, lines.count)
                let indentation = String(repeating: " ", count: block.propertyIndent)
                lines.insert("\(indentation)disabled: \(enabled ? "false" : "true")", at: insertAt)
            }
        } else {
            if !lines.isEmpty { lines.append("") }
            lines.append("- id: dsh-market")
            lines.append("  name: dshmarket")
            lines.append("  disabled: \(enabled ? "false" : "true")")
        }

        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: url, options: .atomic)
    }

    public func removeMarketEntry() throws {
        try ensureProfileDirectory()
        let url = try safeFileURL(patchFileName)
        guard fileManager.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        guard data.count <= 256 * 1024 else {
            throw PluginMarketManagerError.malformedProfile("cordis.patch.yml 过大")
        }
        let existing = String(decoding: data, as: UTF8.self)
        let lines = existing.components(separatedBy: "\n")
        let blocks = try patchBlocks(in: existing)
        let marketBlocks = blocks.filter(\.isMarket)
        guard marketBlocks.count <= 1 else {
            throw PluginMarketManagerError.malformedProfile("Plugin Market 补丁条目重复")
        }
        guard let block = marketBlocks.first else { return }
        let removalRange = patchRemovalRange(for: block, lines: lines)
        var next: [String] = []
        next.append(contentsOf: lines[..<removalRange.lowerBound])
        next.append(contentsOf: lines[removalRange.upperBound..<lines.count])
        while next.last == "" { next.removeLast() }
        if next.isEmpty {
            try fileManager.removeItem(at: url)
        } else {
            try Data((next.joined(separator: "\n") + "\n").utf8)
                .write(to: url, options: .atomic)
        }
    }

    private func patchRemovalRange(
        for block: PatchBlock,
        lines: [String]
    ) -> Range<Int> {
        guard block.start > 0 else { return block.start..<block.end }
        let blockIndent = lines[block.start].prefix { $0 == " " || $0 == "\t" }.count
        var containerStart: Int?
        for index in stride(from: block.start - 1, through: 0, by: -1) {
            let stripped = lines[index].trimmingCharacters(in: .whitespaces)
            let indent = lines[index].prefix { $0 == " " || $0 == "\t" }.count
            if indent < blockIndent,
               stripped.range(of: #"^-\s+insert:\s*$"#, options: .regularExpression) != nil {
                containerStart = index
                break
            }
            if !stripped.isEmpty, indent < blockIndent, !stripped.hasPrefix("#") {
                break
            }
        }
        guard let containerStart else { return block.start..<block.end }

        let hasAnotherEntry = lines[(containerStart + 1)..<block.start].contains { line in
            let stripped = line.trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty, !stripped.hasPrefix("#") else { return false }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            return indent == blockIndent && stripped.hasPrefix("- id:")
        } || lines[block.end..<lines.count].contains { line in
            let stripped = line.trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty, !stripped.hasPrefix("#") else { return false }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            return indent == blockIndent && stripped.hasPrefix("- id:")
        }
        return hasAnotherEntry ? block.start..<block.end : containerStart..<block.end
    }

    public static func isSafeProfileName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && name != "node_modules"
            && !name.contains("/")
            && !name.contains("\\")
            && !name.contains("\0")
    }

    private func safeFileURL(_ relativePath: String) throws -> URL {
        try validatePath()
        try validateRelativePath(relativePath)
        let url = profileDirectory.appendingPathComponent(relativePath, isDirectory: false)
        guard url.standardizedFileURL.path.hasPrefix(profileDirectory.path + "/") else {
            throw PluginMarketManagerError.unsafeProfile("文件路径逃逸 Profile")
        }
        try validateExistingComponents(
            from: profileDirectory,
            through: url.deletingLastPathComponent()
        )
        try rejectSymlinkIfPresent(url, containedBy: profileDirectory)
        return url
    }

    private func safeDirectoryURL(
        _ relativePath: String,
        allowMissing: Bool
    ) throws -> URL? {
        try validatePath()
        try validateRelativePath(relativePath)
        let url = profileDirectory.appendingPathComponent(relativePath, isDirectory: true)
        guard url.standardizedFileURL.path.hasPrefix(profileDirectory.path + "/") else {
            throw PluginMarketManagerError.unsafeProfile("目录路径逃逸 Profile")
        }
        if !fileManager.fileExists(atPath: url.path) {
            if allowMissing { return nil }
            throw PluginMarketManagerError.malformedProfile("缺少目录 \(relativePath)")
        }
        try validateExistingComponents(from: profileDirectory, through: url)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PluginMarketManagerError.malformedProfile("路径不是目录 \(relativePath)")
        }
        return url
    }

    private func validateExistingComponents(from root: URL, through target: URL) throws {
        let rootPath = root.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            throw PluginMarketManagerError.unsafeProfile("路径组件逃逸 Profile")
        }
        try rejectSymlinkIfPresent(root, containedBy: root)
        var current = root
        let relativePath = String(targetPath.dropFirst(rootPath.count))
        for component in relativePath.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            guard fileManager.fileExists(atPath: current.path) else { continue }
            try rejectSymlinkIfPresent(current, containedBy: root)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: current.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw PluginMarketManagerError.unsafeProfile("Profile 路径中的组件不是目录")
            }
        }
    }

    private func validateRelativePath(_ relativePath: String) throws {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasSuffix("/"),
              components.allSatisfy({ component in
                  !component.isEmpty
                      && component != "."
                      && component != ".."
                      && !component.contains("\\")
                      && !component.contains("\0")
              }) else {
            throw PluginMarketManagerError.unsafeProfile("相对路径无效")
        }
    }

    private func rejectSymlinkIfPresent(_ url: URL, containedBy root: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let type = attributes[.type] as? FileAttributeType,
              type == .typeSymbolicLink else {
            return
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedURL.path == resolvedRoot.path
                || resolvedURL.path.hasPrefix(resolvedRoot.path + "/") else {
            throw PluginMarketManagerError.unsafeProfile("符号链接逃逸 Profile：\(url.lastPathComponent)")
        }
    }

    private func profileBundles(in manifest: [String: Any]) -> [String] {
        guard let dsh = manifest["dsh"] as? [String: Any],
              let profile = dsh["profile"] as? [String: Any],
              let bundles = profile["bundles"] as? [Any] else {
            return []
        }
        return bundles.compactMap { $0 as? String }
    }

    private static func isMarketName(_ name: String) -> Bool {
        name == PluginMarketRelease.packageName || name == "dsh-market"
    }

    private static func hasExpectedBundlePatch(
        in manifest: [String: Any],
        packageDirectory: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let dsh = manifest["dsh"] as? [String: Any],
              let bundle = dsh["bundle"] as? [String: Any],
              let patch = bundle["patch"] as? String else {
            return false
        }
        guard patch == "./cordis.patch.yml" || patch == "cordis.patch.yml" else {
            return false
        }
        let patchURL = packageDirectory.appendingPathComponent("cordis.patch.yml")
        guard let data = fileManager.contents(atPath: patchURL.path) else { return false }
        let actual = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = """
        # dsh bundle patch: inserts this plugin into a profile's layer stack.
        - insert:
            - id: dsh-market
              name: 'dshmarket'
        """.trimmingCharacters(in: .whitespacesAndNewlines)
        return actual == expected
    }

    private static func hasExpectedEntryPoint(
        in manifest: [String: Any],
        packageDirectory: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let main = manifest["main"] as? String,
              main == "lib/index.js" else {
            return false
        }
        let entryPoint = packageDirectory.appendingPathComponent(main, isDirectory: false)
        return fileManager.isReadableFile(atPath: entryPoint.path)
    }

    private struct PatchBlock {
        let start: Int
        let end: Int
        let propertyIndent: Int
        let isMarket: Bool
        let disabled: Bool
    }

    private func patchBlocks(in text: String) throws -> [PatchBlock] {
        let lines = text.components(separatedBy: "\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }

        var starts: [(index: Int, indent: Int, id: String)] = []
        for (index, line) in lines.enumerated() {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty || stripped.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            guard stripped.hasPrefix("- id:") else { continue }
            let rawID = String(stripped.dropFirst("- id:".count))
                .split(whereSeparator: { $0 == "#" || $0 == " " || $0 == "\t" })
                .first
            if let rawID, !rawID.isEmpty {
                starts.append((index, indent, String(rawID)))
            }
        }
        guard !starts.isEmpty else {
            let hasInsertEntry = lines.contains {
                $0.range(of: #"^\s*-\s+insert:\s*$"#, options: .regularExpression) != nil
            }
            let meaningfulLines = lines.compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
                return trimmed
            }
            if hasInsertEntry || meaningfulLines == ["[]"] {
                return []
            }
            throw PluginMarketManagerError.malformedProfile("无法识别 cordis.patch.yml 的条目结构")
        }

        var blocks: [PatchBlock] = []
        for (offset, start) in starts.enumerated() {
            let next = starts.dropFirst(offset + 1).first { $0.indent <= start.indent }?.index ?? lines.count
            let slice = lines[start.index..<next]
            let name = patchProperty("name", in: slice)
            let disabledValue = patchProperty("disabled", in: slice)
            let propertyIndent = slice.dropFirst().first { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("#")
            }.map { line in
                line.prefix { $0 == " " || $0 == "\t" }.count
            } ?? (start.indent + 2)
            blocks.append(PatchBlock(
                start: start.index,
                end: next,
                propertyIndent: propertyIndent,
                isMarket: start.id == "dsh-market"
                    || start.id == "dshmarket"
                    || name == "dsh-market"
                    || name == "dshmarket",
                disabled: disabledValue?.lowercased() == "true"
            ))
        }
        return blocks
    }

    private func patchProperty(
        _ key: String,
        in lines: ArraySlice<String>
    ) -> String? {
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key + ":") else { continue }
            var value = String(trimmed.dropFirst(key.count + 1))
                .trimmingCharacters(in: .whitespaces)
            if let comment = value.firstIndex(of: "#") {
                value = String(value[..<comment]).trimmingCharacters(in: .whitespaces)
            }
            if value.hasPrefix("'") && value.hasSuffix("'") {
                value.removeFirst()
                value.removeLast()
            } else if value.hasPrefix("\"") && value.hasSuffix("\"") {
                value.removeFirst()
                value.removeLast()
            }
            return value
        }
        return nil
    }
}
