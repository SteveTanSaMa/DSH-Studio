//
//  RuntimeCrashReportStore.swift
//  DSH Studio
//

import DeepSeekLogging
import Foundation

/// Persists bounded, redacted reports for unexpected Harness exits.
public struct RuntimeCrashReportStore {
    private static let maxReports = 12
    private static let maxReportBytes = 1 * 1024 * 1024

    private let directoryURL: URL
    private let fileManager: FileManager

    /// Creates a crash-report store rooted at one app-owned directory.
    public init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    /// Writes one report and removes older reports beyond the retention limit.
    ///
    /// - Returns: The report URL when writing succeeds, otherwise `nil`.
    @discardableResult
    public func write(
        status: Int32,
        state: RuntimeState,
        generation: Int,
        processID: Int32?,
        configuration: RuntimeConfiguration,
        nodeVersion: String?,
        harnessVersion: String?,
        stderr: [String],
        logs: [RuntimeLogEntry],
        date: Date = Date()
    ) -> URL? {
        let report = render(
            status: status,
            state: state,
            generation: generation,
            processID: processID,
            configuration: configuration,
            nodeVersion: nodeVersion,
            harnessVersion: harnessVersion,
            stderr: stderr,
            logs: logs,
            date: date
        )
        let data = Data(report.utf8)
        guard data.count <= Self.maxReportBytes else { return nil }

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let url = directoryURL.appendingPathComponent("crash-\(fileStamp(date)).log")
            let destination = uniqueURL(for: url)
            try data.write(to: destination, options: .atomic)
            prune()
            return destination
        } catch {
            return nil
        }
    }

    private func render(
        status: Int32,
        state: RuntimeState,
        generation: Int,
        processID: Int32?,
        configuration: RuntimeConfiguration,
        nodeVersion: String?,
        harnessVersion: String?,
        stderr: [String],
        logs: [RuntimeLogEntry],
        date: Date
    ) -> String {
        let header = [
            "DSH Studio Runtime crash report",
            "timestamp: \(ISO8601DateFormatter().string(from: date))",
            "exit status: \(status)",
            "state: \(String(describing: state))",
            "generation: \(generation)",
            "process id: \(processID.map(String.init) ?? "unknown")",
            "profile: \(configuration.profileName)",
            "workspace: \(LogRedactor.redactPath(configuration.workspace.path))",
            "data home: \(LogRedactor.redactPath(configuration.dshHome.path))",
            "node version: \(nodeVersion ?? "unknown")",
            "harness version: \(harnessVersion ?? "unknown")"
        ]
        let stderrLines = stderr.suffix(80).map { LogRedactor.redact($0) }
        let logLines = logs.suffix(160).map { entry in
            let timestamp = ISO8601DateFormatter().string(from: entry.timestamp)
            return "\(timestamp)\t\(entry.level)\t\(entry.component)\t\(LogRedactor.redact(entry.message))"
        }
        return (header + ["", "[stderr]"] + stderrLines + ["", "[recent logs]"] + logLines)
            .joined(separator: "\n") + "\n"
    }

    private func uniqueURL(for url: URL) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        return url.deletingPathExtension()
            .appendingPathExtension(UUID().uuidString)
            .appendingPathExtension("log")
    }

    private func prune() {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let reports = urls.filter { $0.lastPathComponent.hasPrefix("crash-") && $0.pathExtension == "log" }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
        for url in reports.dropFirst(Self.maxReports) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS'Z'"
        return formatter.string(from: date)
    }
}
