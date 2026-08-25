//
//  DiagnosticsExporter.swift
//  DSH Studio
//

import AppKit
import DeepSeekLogging
import Foundation

enum DiagnosticsExportError: Error, LocalizedError {
    case archiveFailed(String)
    case saveCancelled

    var errorDescription: String? {
        switch self {
        case .archiveFailed(let detail):
            return "诊断包生成失败：\(detail)"
        case .saveCancelled:
            return "已取消保存诊断包"
        }
    }
}

@MainActor
enum DiagnosticsExporter {
    static func export(
        systemInfo: String,
        logsDirectory: URL,
        supportDirectory: URL,
        fileManager: FileManager = .default
    ) async throws -> URL {
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("DSH-Studio-Diagnostics-\(UUID().uuidString)", isDirectory: true)
        let archive = fileManager.temporaryDirectory
            .appendingPathComponent("DSH-Studio-Diagnostics-\(timestamp()).zip", isDirectory: false)
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: archive)
        }

        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(systemInfo.utf8).write(
            to: staging.appendingPathComponent("system-info.txt"),
            options: .atomic
        )
        if fileManager.fileExists(atPath: logsDirectory.path) {
            try fileManager.copyItem(
                at: logsDirectory,
                to: staging.appendingPathComponent("logs", isDirectory: true)
            )
        }
        let runtimeManifest = supportDirectory.appendingPathComponent("Runtime/manifest.json")
        if fileManager.fileExists(atPath: runtimeManifest.path) {
            try fileManager.copyItem(
                at: runtimeManifest,
                to: staging.appendingPathComponent("runtime-manifest.json")
            )
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
