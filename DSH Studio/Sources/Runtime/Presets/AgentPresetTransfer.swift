//
//  AgentPresetTransfer.swift
//  DSH Studio
//

import Foundation

/// The `manifest.json` header that describes one exported preset archive.
///
/// The manifest covers the archive itself; the composition files under `preset/`
/// stay owned by the Runtime.
public struct AgentPresetPackageManifest: Codable, Equatable, Sendable {
    /// The archive format identifier written into every export.
    public static let format = "dsh-preset"
    /// The manifest schema version this app writes and accepts.
    public static let currentVersion = 1

    /// The format identifier read from an imported manifest.
    public let format: String
    /// The schema version read from an imported manifest.
    public let version: Int
    /// The preset identifier, which also names the exported directory.
    public let id: String
    /// The display name recorded at export time.
    public let name: String
    /// An optional description carried by the archive; local exports leave it empty.
    public let description: String?
    /// The Harness version that produced the archive, when the exporter knew it.
    public let sourceHarnessVersion: String?
    /// The ISO-8601 timestamp of the export.
    public let exportedAt: String

    /// Creates a manifest, stamping the current format and schema version.
    ///
    /// - Parameters:
    ///   - id: Preset identifier; becomes the directory name inside the archive.
    ///   - name: Display name shown to the user.
    ///   - description: Optional note stored alongside the preset.
    ///   - sourceHarnessVersion: Harness version that produced the preset.
    ///   - exportedAt: ISO-8601 export time; defaults to now.
    public init(
        id: String,
        name: String,
        description: String? = nil,
        sourceHarnessVersion: String? = nil,
        exportedAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.format = Self.format
        self.version = Self.currentVersion
        self.id = id
        self.name = name
        self.description = description
        self.sourceHarnessVersion = sourceHarnessVersion
        self.exportedAt = exportedAt
    }
}

/// What an import would do, computed before anything is written to disk.
///
/// A successful import returns the same preview, so callers can report the
/// installed identifier and any non-fatal findings.
public struct AgentPresetImportPreview: Equatable, Sendable {
    /// The manifest read from the archive.
    public let manifest: AgentPresetPackageManifest
    /// The identifier the preset would be installed under.
    ///
    /// A requested identifier is sanitised first; otherwise the archive's own
    /// identifier is used.
    public let targetID: String
    /// Whether a preset with ``targetID`` already exists.
    public let conflict: Bool
    /// The number of regular files the archive would install.
    public let fileCount: Int
    /// The summed size of those files after extraction.
    public let uncompressedBytes: Int64
    /// Non-fatal findings collected while validating the archive.
    public let warnings: [String]

    /// Creates a preview for one inspected archive.
    ///
    /// - Parameters:
    ///   - manifest: Manifest read from the archive.
    ///   - targetID: Identifier the preset would be installed under.
    ///   - conflict: Whether that identifier is already taken.
    ///   - fileCount: Number of files that would be installed.
    ///   - uncompressedBytes: Total size of those files.
    ///   - warnings: Non-fatal findings to surface to the user.
    public init(
        manifest: AgentPresetPackageManifest,
        targetID: String,
        conflict: Bool,
        fileCount: Int,
        uncompressedBytes: Int64,
        warnings: [String]
    ) {
        self.manifest = manifest
        self.targetID = targetID
        self.conflict = conflict
        self.fileCount = fileCount
        self.uncompressedBytes = uncompressedBytes
        self.warnings = warnings
    }
}

/// Whether a discovered user preset can be composed by the Runtime.
public enum AgentPresetStatus: String, Codable, Equatable, Sendable {
    /// The preset has a readable composition file.
    case ready
    /// The preset is present but unusable; see ``AgentPresetSummary/problem``.
    case invalid

    /// A localized label for the status.
    public var displayName: String {
        switch self {
        case .ready:
            return "可用"
        case .invalid:
            return "不可用"
        }
    }
}

/// A read-only description of one user preset directory.
public struct AgentPresetSummary: Codable, Equatable, Sendable {
    /// The preset identifier, equal to its directory name.
    public let id: String
    /// The display name from the preset metadata, falling back to the identifier.
    public let name: String
    /// The preset directory under `DSH_HOME/.agent-presets`.
    public let directory: URL
    /// The number of regular files found in the preset.
    public let fileCount: Int
    /// The summed size of those files.
    public let totalBytes: Int64
    /// Whether the Runtime can compose this preset.
    public let status: AgentPresetStatus
    /// Why the preset is unusable, when ``status`` is ``AgentPresetStatus/invalid``.
    public let problem: String?

    /// Creates a summary for one inspected preset directory.
    ///
    /// - Parameters:
    ///   - id: Preset identifier, equal to the directory name.
    ///   - name: Display name read from the preset metadata, falling back to the id.
    ///   - directory: Absolute preset directory.
    ///   - fileCount: Number of regular files in the preset.
    ///   - totalBytes: Total size of those files.
    ///   - status: Whether the Runtime can compose the preset.
    ///   - problem: Reason the preset is unusable, when it is.
    public init(
        id: String,
        name: String,
        directory: URL,
        fileCount: Int,
        totalBytes: Int64,
        status: AgentPresetStatus,
        problem: String? = nil
    ) {
        self.id = id
        self.name = name
        self.directory = directory
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.status = status
        self.problem = problem
    }
}

/// Failures raised while exporting or importing a preset archive.
///
/// Associated values carry the offending path, identifier, or diagnostic detail;
/// the user-facing sentence is produced by ``errorDescription``.
public enum AgentPresetTransferError: Error, Equatable, LocalizedError, Sendable {
    /// The user dismissed a file panel before choosing a location.
    case cancelled
    /// The preset identifier is not a safe directory name.
    case invalidPresetID
    /// No user preset directory exists for the requested identifier.
    case presetNotFound
    /// The preset is shipped with the Runtime and cannot be exported.
    case builtInPreset
    /// A file already exists at the chosen export destination.
    case destinationExists
    /// The preset has no readable `agent.cordis.yml`.
    case missingComposition
    /// The archive contains an absolute or escaping path.
    case unsafeArchiveEntry(String)
    /// `manifest.json` is missing, undecodable, or of an unknown format or version.
    case invalidManifest(String)
    /// The archive format could not be recognised.
    case unsupportedArchive
    /// The archive or its extracted tree exceeds the configured size limits.
    case archiveTooLarge
    /// The archive contains more files than ``AgentPresetTransferManager/maxFileCount``.
    case tooManyFiles
    /// The archive contains a symbolic link.
    case symlinkNotAllowed(String)
    /// The archive contains a file type the preset contract does not allow.
    case unsupportedFile(String)
    /// A preset with the target identifier already exists.
    case conflict(String)
    /// The zip tool failed while packing or unpacking the archive.
    case archiveFailed(String)

    /// A localized, user-facing description of the failure.
    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "操作已取消"
        case .invalidPresetID:
            return "Agent Preset 名称无效"
        case .presetNotFound:
            return "Agent Preset 不存在"
        case .builtInPreset:
            return "内置 Agent Preset 不能导出"
        case .destinationExists:
            return "目标文件已存在"
        case .missingComposition:
            return "缺少 agent.cordis.yml"
        case .unsafeArchiveEntry(let path):
            return "Preset 压缩包包含不安全路径：\(path)"
        case .invalidManifest(let detail):
            return "Preset manifest 无效：\(detail)"
        case .unsupportedArchive:
            return "不是有效的 DSH Preset 压缩包"
        case .archiveTooLarge:
            return "Preset 压缩包超过大小限制"
        case .tooManyFiles:
            return "Preset 文件数量超过限制"
        case .symlinkNotAllowed(let path):
            return "Preset 不允许符号链接：\(path)"
        case .unsupportedFile(let path):
            return "Preset 包含不支持的文件：\(path)"
        case .conflict(let id):
            return "Agent Preset 已存在：\(id)"
        case .archiveFailed(let detail):
            return "Preset 压缩包处理失败：\(detail)"
        }
    }
}

/// Native transfer boundary for user-authored Agent Presets.
///
/// The Runtime owns preset discovery and composition semantics. This type owns
/// only a portable archive contract: it never includes credentials, Sessions,
/// workspace files, or the app's other DSH_HOME data.
public final class AgentPresetTransferManager: @unchecked Sendable {
    /// The directory under `DSH_HOME` that holds user presets.
    public static let userPresetDirectoryName = ".agent-presets"
    /// The composition file every exportable preset must contain.
    public static let compositionFileName = "agent.cordis.yml"
    /// The Runtime-owned metadata file that travels with a preset.
    public static let metadataFileName = "preset.yml"
    /// Upper bound for a produced archive; checked before the file is handed back.
    public static let maxCompressedBytes: Int64 = 16 * 1024 * 1024
    /// Upper bound for an archive's extracted tree.
    public static let maxUncompressedBytes: Int64 = 32 * 1024 * 1024
    /// Upper bound for a single file inside an archive.
    public static let maxFileBytes: Int64 = 12 * 1024 * 1024
    /// Upper bound for the number of files inside an archive.
    public static let maxFileCount = 256

    /// The standardized `DSH_HOME` this manager reads and writes.
    public let dshHome: URL
    /// `DSH_HOME/.agent-presets`; the only directory imports are installed into.
    public let userPresetRoot: URL
    /// Where the most-recently-used preset list is persisted.
    public let recentStateURL: URL

    private let fileManager: FileManager

    /// Creates a manager rooted at `dshHome`.
    ///
    /// - Parameters:
    ///   - dshHome: Harness data home; a non-standardized value is standardized here.
    ///   - fileManager: File system seam used by tests.
    public init(dshHome: URL, fileManager: FileManager = .default) {
        self.dshHome = dshHome.standardizedFileURL
        self.userPresetRoot = self.dshHome
            .appendingPathComponent(Self.userPresetDirectoryName, isDirectory: true)
        self.recentStateURL = self.dshHome
            .appendingPathComponent(".dsh-studio", isDirectory: true)
            .appendingPathComponent("preset-recent.json", isDirectory: false)
        self.fileManager = fileManager
    }

    /// Whether `id` is usable as a preset directory name.
    ///
    /// Accepted form: 1–64 characters from `a-z`, `0-9`, and `-`, starting with a
    /// letter or digit. The check keeps discovery and import inside one directory
    /// level and rejects path separators or dot names.
    ///
    /// - Parameter id: Candidate identifier.
    /// - Returns: `true` when the identifier may be used as a directory name.
    public static func isSafePresetID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 64,
              let first = id.utf8.first,
              first >= 48 && first <= 57 || first >= 97 && first <= 122 else {
            return false
        }
        return id.utf8.dropFirst().allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 122) || $0 == 45
        }
    }

    /// Lists installed presets, optionally filtered by a case-insensitive query.
    ///
    /// The query is matched against the identifier, the display name, and any
    /// problem text, which makes a failing preset findable by its error.
    ///
    /// - Parameter query: Text to match; an empty or `nil` query returns everything.
    /// - Returns: Matching presets sorted by localized name.
    public func search(query: String? = nil) -> [AgentPresetSummary] {
        let normalized = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let values = summaries()
        guard !normalized.isEmpty else { return values }
        return values.filter {
            $0.id.lowercased().contains(normalized)
                || $0.name.lowercased().contains(normalized)
                || ($0.problem?.lowercased().contains(normalized) == true)
        }
    }

    /// Lists presets with recently used ones first.
    ///
    /// - Parameters:
    ///   - limit: Maximum number of presets to return; values below zero yield none.
    ///   - query: Optional filter applied before ordering.
    /// - Returns: Recent presets first, then the remaining matches by localized name.
    public func recentPresets(limit: Int = 5, query: String? = nil) -> [AgentPresetSummary] {
        let candidates = search(query: query)
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let recent = recentIDs().compactMap { byID[$0] }
        let remaining = candidates
            .filter { !recent.contains($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Array((recent + remaining).prefix(max(0, limit)))
    }

    /// Whether `id` appears in the persisted recent list.
    ///
    /// - Parameter id: Preset identifier.
    /// - Returns: `true` when the identifier was recorded recently.
    public func isRecentlyUsed(id: String) -> Bool {
        recentIDs().contains(id)
    }

    /// Moves `id` to the front of the recent list, keeping the newest 20 entries.
    ///
    /// Unsafe identifiers and presets that are not installed are ignored, and a
    /// failed write is swallowed: usage history is a convenience, never a
    /// precondition for preset operations.
    ///
    /// - Parameter id: Preset identifier to record.
    public func recordUsage(id: String) {
        guard Self.isSafePresetID(id), summaries().contains(where: { $0.id == id }) else { return }
        var ids = recentIDs().filter { $0 != id }
        ids.insert(id, at: 0)
        ids = Array(ids.prefix(20))
        try? fileManager.createDirectory(
            at: recentStateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? JSONEncoder().encode(ids).write(to: recentStateURL, options: .atomic)
    }

    /// Describes every installed user preset.
    ///
    /// Entries that are not plain directories, or whose names fail
    /// ``isSafePresetID(_:)``, are skipped rather than reported.
    ///
    /// - Returns: Presets sorted by localized name.
    public func summaries() -> [AgentPresetSummary] {
        guard isNonSymlinkDirectory(userPresetRoot),
              let entries = try? fileManager.contentsOfDirectory(
                  at: userPresetRoot,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        return entries.compactMap { entry in
            guard Self.isSafePresetID(entry.lastPathComponent), isNonSymlinkDirectory(entry) else {
                return nil
            }
            return inspectPreset(id: entry.lastPathComponent, directory: entry)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Writes `presetID` to `destination` as a `.dshpreset` archive.
    ///
    /// The archive is staged in the temporary directory and only copied to
    /// `destination` after the manifest is written and the compressed size passes
    /// ``maxCompressedBytes``; the staging directory is removed either way.
    ///
    /// - Parameters:
    ///   - presetID: Identifier of the user preset to export.
    ///   - destination: File URL to create; it must not exist yet.
    ///   - sourceHarnessVersion: Harness version recorded in the manifest.
    /// - Throws: ``AgentPresetTransferError`` when the preset is missing, the
    ///   destination exists, or the tree exceeds the size and file-count limits.
    public func exportArchive(
        presetID: String,
        to destination: URL,
        sourceHarnessVersion: String? = nil
    ) throws {
        guard Self.isSafePresetID(presetID) else {
            throw AgentPresetTransferError.invalidPresetID
        }
        guard isNonSymlinkDirectory(userPresetRoot) else {
            throw AgentPresetTransferError.presetNotFound
        }
        let source = userPresetRoot.appendingPathComponent(presetID, isDirectory: true)
        guard isNonSymlinkDirectory(source) else {
            throw AgentPresetTransferError.presetNotFound
        }
        let composition = source.appendingPathComponent(Self.compositionFileName)
        guard isNonSymlinkRegularFile(composition) else {
            throw AgentPresetTransferError.missingComposition
        }
        try validateComposition(composition, relativePath: Self.compositionFileName)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw AgentPresetTransferError.destinationExists
        }

        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("DSHStudio-PresetExport-\(UUID().uuidString)", isDirectory: true)
        let archive = fileManager.temporaryDirectory
            .appendingPathComponent("DSHStudio-PresetExport-\(UUID().uuidString).zip")
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: archive)
        }

        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let tree = try inspectTree(source, relativePath: "preset")
        guard tree.files <= Self.maxFileCount,
              tree.bytes <= Self.maxUncompressedBytes else {
            throw AgentPresetTransferError.archiveTooLarge
        }
        try copyAllowedTree(
            from: source,
            to: staging.appendingPathComponent("preset", isDirectory: true),
            relativePath: "preset"
        )
        let manifest = AgentPresetPackageManifest(
            id: presetID,
            name: presetID,
            sourceHarnessVersion: sourceHarnessVersion
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: staging.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        _ = try run(
            executable: URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-q", "-r", archive.path, "manifest.json", "preset"],
            currentDirectory: staging
        )
        guard let size = try? fileManager.attributesOfItem(atPath: archive.path)[.size] as? NSNumber,
              size.int64Value <= Self.maxCompressedBytes else {
            throw AgentPresetTransferError.archiveTooLarge
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: archive, to: destination)
        recordUsage(id: presetID)
    }

    /// Validates an archive and reports what importing it would do.
    ///
    /// Nothing is written to `DSH_HOME`: the archive is extracted into a temporary
    /// directory that is deleted before returning.
    ///
    /// - Parameters:
    ///   - archive: Archive to inspect.
    ///   - requestedID: Identifier to install under; sanitised when omitted.
    /// - Returns: The preview, including conflicts and warnings.
    /// - Throws: ``AgentPresetTransferError`` when the archive is unreadable or unsafe.
    public func previewImport(from archive: URL, requestedID: String? = nil) throws -> AgentPresetImportPreview {
        try withExtractedArchive(archive) { root in
            try inspectExtractedArchive(root, requestedID: requestedID)
        }
    }

    /// Installs a preset archive into `DSH_HOME/.agent-presets`.
    ///
    /// The archive is validated first and never overwrites an existing preset: a
    /// conflicting identifier throws instead of merging. The recorded usage history
    /// is updated on success.
    ///
    /// - Parameters:
    ///   - archive: Archive to install.
    ///   - requestedID: Identifier to install under; sanitised when omitted.
    /// - Returns: The preview describing what was installed.
    /// - Throws: ``AgentPresetTransferError`` when validation fails or the target
    ///   identifier already exists.
    @discardableResult
    public func installImport(from archive: URL, requestedID: String? = nil) throws -> AgentPresetImportPreview {
        try withExtractedArchive(archive) { root in
            let preview = try inspectExtractedArchive(root, requestedID: requestedID)
            guard !preview.conflict else {
                throw AgentPresetTransferError.conflict(preview.targetID)
            }
            try ensureUserPresetRoot()
            let target = userPresetRoot.appendingPathComponent(preview.targetID, isDirectory: true)
            guard !fileManager.fileExists(atPath: target.path) else {
                throw AgentPresetTransferError.conflict(preview.targetID)
            }
            try fileManager.moveItem(
                at: root.appendingPathComponent("preset", isDirectory: true),
                to: target
            )
            recordUsage(id: preview.targetID)
            return preview
        }
    }

    private func inspectPreset(id: String, directory: URL) -> AgentPresetSummary {
        let composition = directory.appendingPathComponent(Self.compositionFileName)
        guard isNonSymlinkRegularFile(composition) else {
            return AgentPresetSummary(
                id: id,
                name: id,
                directory: directory,
                fileCount: 0,
                totalBytes: 0,
                status: .invalid,
                problem: "缺少 agent.cordis.yml"
            )
        }
        do {
            let tree = try inspectTree(directory, relativePath: id)
            let metadata = readMetadata(from: directory.appendingPathComponent(Self.metadataFileName))
            return AgentPresetSummary(
                id: id,
                name: metadata.name ?? id,
                directory: directory,
                fileCount: tree.files,
                totalBytes: tree.bytes,
                status: .ready,
                problem: nil
            )
        } catch {
            return AgentPresetSummary(
                id: id,
                name: id,
                directory: directory,
                fileCount: 0,
                totalBytes: 0,
                status: .invalid,
                problem: error.localizedDescription
            )
        }
    }

    private func readMetadata(from url: URL) -> (name: String?, description: String?) {
        guard isNonSymlinkRegularFile(url),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return (nil, nil)
        }
        var name: String?
        var description: String?
        for line in text.split(whereSeparator: { $0.isNewline }).map(String.init) {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if key == "name" { name = value.isEmpty ? nil : value }
            if key == "description" { description = value.isEmpty ? nil : value }
        }
        return (name, description)
    }

    private func recentIDs() -> [String] {
        guard let data = try? Data(contentsOf: recentStateURL),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return ids.filter(Self.isSafePresetID)
    }

    private func withExtractedArchive<T>(
        _ archive: URL,
        body: (URL) throws -> T
    ) throws -> T {
        guard isNonSymlinkRegularFile(archive) else {
            throw AgentPresetTransferError.unsupportedArchive
        }
        guard let size = try? fileManager.attributesOfItem(atPath: archive.path)[.size] as? NSNumber,
              size.int64Value <= Self.maxCompressedBytes else {
            throw AgentPresetTransferError.archiveTooLarge
        }
        try validateArchiveEntries(archive)
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("DSHStudio-PresetImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        _ = try run(
            executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-qq", "-o", archive.path, "-d", staging.path],
            currentDirectory: nil
        )
        return try body(staging)
    }

    private func inspectExtractedArchive(
        _ root: URL,
        requestedID: String?
    ) throws -> AgentPresetImportPreview {
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard isNonSymlinkRegularFile(manifestURL) else {
            throw AgentPresetTransferError.invalidManifest("缺少 manifest.json")
        }
        let manifest: AgentPresetPackageManifest
        do {
            manifest = try JSONDecoder().decode(
                AgentPresetPackageManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw AgentPresetTransferError.invalidManifest(error.localizedDescription)
        }
        guard manifest.format == AgentPresetPackageManifest.format,
              manifest.version == AgentPresetPackageManifest.currentVersion else {
            throw AgentPresetTransferError.invalidManifest("format 或 version 不受支持")
        }
        guard Self.isSafePresetID(manifest.id) else {
            throw AgentPresetTransferError.invalidManifest("id 无效")
        }
        let targetID = requestedID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? manifest.id
        guard Self.isSafePresetID(targetID) else {
            throw AgentPresetTransferError.invalidPresetID
        }
        let presetRoot = root.appendingPathComponent("preset", isDirectory: true)
        guard isNonSymlinkDirectory(presetRoot) else {
            throw AgentPresetTransferError.missingComposition
        }
        let composition = presetRoot.appendingPathComponent(Self.compositionFileName)
        guard isNonSymlinkRegularFile(composition) else {
            throw AgentPresetTransferError.missingComposition
        }
        let compositionSize = try fileSize(composition)
        guard compositionSize > 0, compositionSize <= 2 * 1024 * 1024 else {
            throw AgentPresetTransferError.unsupportedFile(Self.compositionFileName)
        }
        try validateComposition(composition, relativePath: Self.compositionFileName)
        let tree = try inspectTree(presetRoot, relativePath: "preset")
        guard tree.bytes <= Self.maxUncompressedBytes else {
            throw AgentPresetTransferError.archiveTooLarge
        }

        var warnings: [String] = [
            "Preset composition 可加载插件并以 Agent 权限执行工具，请只导入可信来源。"
        ]
        if containsSensitiveMarker(in: presetRoot) {
            warnings.append("Preset 文件包含可能的 token、secret、password 或 API key 字样，请在导入前检查。")
        }
        if let sourceVersion = manifest.sourceHarnessVersion,
           !sourceVersion.isEmpty {
            warnings.append("该 Preset 来自 Harness \(sourceVersion)，当前 Runtime 可能存在组合兼容性差异。")
        }
        return AgentPresetImportPreview(
            manifest: manifest,
            targetID: targetID,
            conflict: fileManager.fileExists(
                atPath: userPresetRoot.appendingPathComponent(targetID, isDirectory: true).path
            ),
            fileCount: tree.files,
            uncompressedBytes: tree.bytes,
            warnings: warnings
        )
    }

    private func validateArchiveEntries(_ archive: URL) throws {
        let listing = try run(
            executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-Z1", archive.path],
            currentDirectory: nil
        )
        let entries = listing.stdout.split(whereSeparator: { $0.isNewline }).map(String.init)
        guard !entries.isEmpty else { throw AgentPresetTransferError.unsupportedArchive }
        var fileCount = 0
        let normalizedEntries = try entries.compactMap { rawEntry in
            try normalizedArchiveEntry(rawEntry)
        }
        var seenEntries = Set<String>()
        for entry in normalizedEntries {
            guard seenEntries.insert(entry).inserted else {
                throw AgentPresetTransferError.unsafeArchiveEntry(entry)
            }
            if entry.hasSuffix("/") { continue }
            fileCount += 1
            guard fileCount <= Self.maxFileCount else {
                throw AgentPresetTransferError.tooManyFiles
            }
        }
        guard normalizedEntries.contains("manifest.json"),
              normalizedEntries.contains(Self.compositionFileName)
                || normalizedEntries.contains("preset/\(Self.compositionFileName)") else {
            throw AgentPresetTransferError.missingComposition
        }
    }

    private func normalizedArchiveEntry(_ raw: String) throws -> String? {
        guard !raw.isEmpty else { throw AgentPresetTransferError.unsafeArchiveEntry(raw) }
        if raw.hasPrefix("__MACOSX/") || raw.split(separator: "/").last == ".DS_Store" {
            return nil
        }
        guard !raw.contains("\\"), !raw.hasPrefix("/"), !raw.hasPrefix("~") else {
            throw AgentPresetTransferError.unsafeArchiveEntry(raw)
        }
        let trimmed = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw AgentPresetTransferError.unsafeArchiveEntry(raw)
        }
        let normalized = parts.joined(separator: "/")
        guard normalized == "manifest.json" || normalized == "preset" || normalized.hasPrefix("preset/") else {
            throw AgentPresetTransferError.unsafeArchiveEntry(raw)
        }
        return raw.hasSuffix("/") ? normalized + "/" : normalized
    }

    private func copyAllowedTree(from source: URL, to destination: URL, relativePath: String) throws {
        guard isNonSymlinkDirectory(source) else {
            throw AgentPresetTransferError.presetNotFound
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for entry in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            if Self.ignoredFileNames.contains(entry.lastPathComponent) { continue }
            let relative = "\(relativePath)/\(entry.lastPathComponent)"
            if isNonSymlinkDirectory(entry) {
                try copyAllowedTree(
                    from: entry,
                    to: destination.appendingPathComponent(entry.lastPathComponent, isDirectory: true),
                    relativePath: relative
                )
            } else if isNonSymlinkRegularFile(entry) {
                guard try fileSize(entry) <= Self.maxFileBytes else {
                    throw AgentPresetTransferError.archiveTooLarge
                }
                try fileManager.copyItem(
                    at: entry,
                    to: destination.appendingPathComponent(entry.lastPathComponent)
                )
            } else if isSymbolicLink(entry) {
                throw AgentPresetTransferError.symlinkNotAllowed(relative)
            } else {
                throw AgentPresetTransferError.unsupportedFile(relative)
            }
        }
    }

    private func inspectTree(_ directory: URL, relativePath: String) throws -> (files: Int, bytes: Int64) {
        guard isNonSymlinkDirectory(directory) else {
            throw AgentPresetTransferError.symlinkNotAllowed(relativePath)
        }
        var files = 0
        var bytes: Int64 = 0
        for entry in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if Self.ignoredFileNames.contains(entry.lastPathComponent) { continue }
            let relative = "\(relativePath)/\(entry.lastPathComponent)"
            if isNonSymlinkDirectory(entry) {
                let nested = try inspectTree(entry, relativePath: relative)
                files += nested.files
                bytes += nested.bytes
            } else if isNonSymlinkRegularFile(entry) {
                files += 1
                guard files <= Self.maxFileCount else { throw AgentPresetTransferError.tooManyFiles }
                let size = try fileSize(entry)
                guard size <= Self.maxFileBytes else {
                    throw AgentPresetTransferError.archiveTooLarge
                }
                bytes += size
            } else if isSymbolicLink(entry) {
                throw AgentPresetTransferError.symlinkNotAllowed(relative)
            } else {
                throw AgentPresetTransferError.unsupportedFile(relative)
            }
        }
        return (files, bytes)
    }

    private func containsSensitiveMarker(in directory: URL) -> Bool {
        guard let tree = try? allRegularFiles(in: directory) else { return false }
        let markers = ["apikey", "api_key", "token", "secret", "password"]
        return tree.contains { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            let lower = text.lowercased()
            return markers.contains(where: lower.contains)
        }
    }

    private func allRegularFiles(in directory: URL) throws -> [URL] {
        var result: [URL] = []
        for entry in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if Self.ignoredFileNames.contains(entry.lastPathComponent) { continue }
            if isNonSymlinkDirectory(entry) {
                result.append(contentsOf: try allRegularFiles(in: entry))
            } else if isNonSymlinkRegularFile(entry) {
                result.append(entry)
            }
        }
        return result
    }

    private func ensureUserPresetRoot() throws {
        if fileManager.fileExists(atPath: userPresetRoot.path) {
            guard isNonSymlinkDirectory(userPresetRoot) else {
                throw AgentPresetTransferError.unsupportedFile(userPresetRoot.path)
            }
            return
        }
        try fileManager.createDirectory(at: userPresetRoot, withIntermediateDirectories: true)
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        guard let value = try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            throw AgentPresetTransferError.unsupportedFile(url.path)
        }
        return value.int64Value
    }

    private func validateComposition(_ url: URL, relativePath: String) throws {
        guard let data = try? Data(contentsOf: url),
              String(data: data, encoding: .utf8) != nil else {
            throw AgentPresetTransferError.unsupportedFile(relativePath)
        }
    }

    private func isNonSymlinkDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func isNonSymlinkRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static let ignoredFileNames: Set<String> = [
        ".DS_Store", "Thumbs.db", "desktop.ini"
    ]

    private struct CommandOutput {
        let stdout: String
    }

    private func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL?
    ) throws -> CommandOutput {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw AgentPresetTransferError.archiveFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        let stdout = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "exit status \(process.terminationStatus)"
            throw AgentPresetTransferError.archiveFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return CommandOutput(stdout: stdout)
    }
}
