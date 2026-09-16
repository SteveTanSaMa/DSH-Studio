//
//  DiagnosticsExporter.swift
//  DSH Studio
//

import AppKit
import DeepSeekLogging
import Foundation

enum DiagnosticsExportError: Error, LocalizedError {
    case archiveFailed(String)
    case evidenceTooLarge
    case unsafeInput(String)
    case saveCancelled

    var errorDescription: String? {
        switch self {
        case .archiveFailed(let detail):
            return "诊断包生成失败：\(detail)"
        case .evidenceTooLarge:
            return "诊断信息超过大小限制"
        case .unsafeInput(let detail):
            return "诊断包包含不安全内容：\(detail)"
        case .saveCancelled:
            return "已取消保存诊断包"
        }
    }
}

@MainActor
enum DiagnosticsExporter {
    private static let maxSystemInfoBytes = 512 * 1024
    private static let maxEvidenceBytes = 2 * 1024 * 1024
    private static let maxLogBytes = 4 * 1024 * 1024
    private static let maxRuntimeManifestBytes = 512 * 1024
    private static let maxTotalStagingBytes = 8 * 1024 * 1024
    private static let maxLogFiles = 32
    private static let allowedEvidenceNames: Set<String> = [
        "runtime-state.json",
        "profiles.json",
        "presets.json",
        "lifecycle.json"
    ]

    static func export(
        systemInfo: String,
        logsDirectory: URL,
        supportDirectory: URL,
        evidence: [String: Data] = [:],
        fileManager: FileManager = .default
    ) async throws -> URL {
        let staging = try prepareStaging(
            systemInfo: systemInfo,
            logsDirectory: logsDirectory,
            supportDirectory: supportDirectory,
            evidence: evidence,
            fileManager: fileManager
        )
        let archive = fileManager.temporaryDirectory
            .appendingPathComponent("DSH-Studio-Diagnostics-\(timestamp()).zip", isDirectory: false)
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: archive)
        }

        try await createArchive(source: staging, destination: archive)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = archive.lastPathComponent
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else {
            throw DiagnosticsExportError.saveCancelled
        }
        try fileManager.copyItem(at: archive, to: destination)
        return destination
    }

    static func prepareStaging(
        systemInfo: String,
        logsDirectory: URL,
        supportDirectory: URL,
        evidence: [String: Data] = [:],
        fileManager: FileManager = .default
    ) throws -> URL {
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("DSH-Studio-Diagnostics-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            let sanitizedSystemInfo = LogRedactor.redact(systemInfo)
            let systemInfoData = Data(sanitizedSystemInfo.utf8)
            guard systemInfoData.count <= maxSystemInfoBytes else {
                throw DiagnosticsExportError.evidenceTooLarge
            }
            try systemInfoData.write(
                to: staging.appendingPathComponent("system-info.txt"),
                options: .atomic
            )
            var stagedBytes = systemInfoData.count
            stagedBytes += try copyLogs(
                from: logsDirectory,
                to: staging.appendingPathComponent("logs", isDirectory: true),
                fileManager: fileManager
            )
            let runtimeManifest = supportDirectory.appendingPathComponent("Runtime/manifest.json")
            if let bytes = try copyBoundedFile(
                from: runtimeManifest,
                to: staging.appendingPathComponent("runtime-manifest.json"),
                maxBytes: maxRuntimeManifestBytes,
                sanitizeText: true,
                fileManager: fileManager
            ) {
                stagedBytes += bytes
            }
            for name in evidence.keys.sorted() {
                guard allowedEvidenceNames.contains(name),
                      name == URL(fileURLWithPath: name).lastPathComponent,
                      !name.contains("..") else {
                    throw DiagnosticsExportError.unsafeInput(name)
                }
                guard let rawData = evidence[name] else { continue }
                let sanitizedData = sanitizeEvidence(rawData)
                guard sanitizedData.count <= maxEvidenceBytes,
                      stagedBytes + sanitizedData.count <= maxTotalStagingBytes else {
                    throw DiagnosticsExportError.evidenceTooLarge
                }
                try sanitizedData.write(
                    to: staging.appendingPathComponent(name, isDirectory: false),
                    options: .atomic
                )
                stagedBytes += sanitizedData.count
            }
            guard stagedBytes <= maxTotalStagingBytes else {
                throw DiagnosticsExportError.evidenceTooLarge
            }
            return staging
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private static func copyLogs(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws -> Int {
        guard isNonSymlinkDirectory(source, fileManager: fileManager) else { return 0 }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var totalBytes = 0
        var fileCount = 0
        for case let fileURL as URL in enumerator {
            let relativePath = fileURL.path.replacingOccurrences(of: source.path + "/", with: "")
            guard !relativePath.isEmpty else { continue }
            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { continue }
            guard fileCount < maxLogFiles else { break }
            let target = destination.appendingPathComponent(relativePath, isDirectory: false)
            guard let bytes = try copyBoundedFile(
                from: fileURL,
                to: target,
                maxBytes: maxLogBytes - totalBytes,
                sanitizeText: true,
                fileManager: fileManager
            ) else { continue }
            totalBytes += bytes
            fileCount += 1
            if totalBytes >= maxLogBytes { break }
        }
        return totalBytes
    }

    private static func copyBoundedFile(
        from source: URL,
        to destination: URL,
        maxBytes: Int,
        sanitizeText: Bool = false,
        fileManager: FileManager
    ) throws -> Int? {
        guard maxBytes > 0,
              isNonSymlinkRegularFile(source, fileManager: fileManager) else { return nil }
        let values = try source.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size <= maxBytes else { return nil }
        let data = try Data(contentsOf: source, options: [.mappedIfSafe])
        let output = sanitizeText ? sanitizeEvidence(data) : data
        guard output.count <= maxBytes else { return nil }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try output.write(to: destination, options: .atomic)
        return output.count
    }

    private static func sanitizeEvidence(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        return Data(LogRedactor.redact(text).utf8)
    }

    private static func isNonSymlinkDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isNonSymlinkRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func createArchive(source: URL, destination: URL) async throws {
        try await Task.detached {
            let process = Process()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--keepParent", source.path, destination.path]
            process.standardError = errorPipe
            do {
                try process.run()
            } catch {
                throw DiagnosticsExportError.archiveFailed(error.localizedDescription)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = String(
                    data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? "ditto exited with status \(process.terminationStatus)"
                throw DiagnosticsExportError.archiveFailed(LogRedactor.redact(detail))
            }
        }.value
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
