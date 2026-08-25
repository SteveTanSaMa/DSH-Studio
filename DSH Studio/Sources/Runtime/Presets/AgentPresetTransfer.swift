//
//  AgentPresetTransfer.swift
//  DSH Studio
//

import Foundation

public struct AgentPresetPackageManifest: Codable, Equatable, Sendable {
    public static let format = "dsh-preset"
    public static let currentVersion = 1

    public let format: String
    public let version: Int
    public let id: String
    public let name: String
    public let description: String?
    public let sourceHarnessVersion: String?
    public let exportedAt: String

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

public struct AgentPresetImportPreview: Equatable, Sendable {
    public let manifest: AgentPresetPackageManifest
    public let targetID: String
    public let conflict: Bool
    public let fileCount: Int
    public let uncompressedBytes: Int64
    public let warnings: [String]

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

public enum AgentPresetTransferError: Error, Equatable, LocalizedError, Sendable {
    case cancelled
    case invalidPresetID
    case presetNotFound
    case builtInPreset
    case destinationExists
    case missingComposition
    case unsafeArchiveEntry(String)
    case invalidManifest(String)
    case unsupportedArchive
    case archiveTooLarge
    case tooManyFiles
    case symlinkNotAllowed(String)
    case unsupportedFile(String)
    case conflict(String)
    case archiveFailed(String)

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
    public static let userPresetDirectoryName = ".agent-presets"
    public static let compositionFileName = "agent.cordis.yml"
    public static let metadataFileName = "preset.yml"
    public static let maxCompressedBytes: Int64 = 16 * 1024 * 1024
    public static let maxUncompressedBytes: Int64 = 32 * 1024 * 1024
    public static let maxFileBytes: Int64 = 12 * 1024 * 1024
    public static let maxFileCount = 256

    public let dshHome: URL
    public let userPresetRoot: URL

    private let fileManager: FileManager

    public init(dshHome: URL, fileManager: FileManager = .default) {
        self.dshHome = dshHome.standardizedFileURL
        self.userPresetRoot = self.dshHome
            .appendingPathComponent(Self.userPresetDirectoryName, isDirectory: true)
        self.fileManager = fileManager
    }

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
    }

    public func previewImport(from archive: URL, requestedID: String? = nil) throws -> AgentPresetImportPreview {
        try withExtractedArchive(archive) { root in
            try inspectExtractedArchive(root, requestedID: requestedID)
        }
    }

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
            return preview
        }
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
