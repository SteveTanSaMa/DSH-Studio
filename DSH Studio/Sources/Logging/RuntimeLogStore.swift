//
//  RuntimeLogStore.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import Combine
import Foundation

/// A structured runtime log entry.
public struct RuntimeLogEntry: Equatable, Sendable {
    /// When the entry was recorded.
    public let timestamp: Date
    /// Severity label, for example `info`, `warn`, `error`, or `stderr`.
    public let level: String
    /// Subsystem that produced the entry, for example `Runtime` or `Harness`.
    public let component: String
    /// Already-redacted message text.
    public let message: String

    /// Creates a log entry.
    ///
    /// - Parameters:
    ///   - timestamp: Time of the event; defaults to now.
    ///   - level: Severity label.
    ///   - component: Subsystem that produced the entry.
    ///   - message: Message text; callers should pass redacted text.
    public init(
        timestamp: Date = Date(),
        level: String,
        component: String,
        message: String
    ) {
        self.timestamp = timestamp
        self.level = level
        self.component = component
        self.message = message
    }
}

/// Collects bounded in-memory logs and writes sanitized logs to disk.
public final class RuntimeLogStore: ObservableObject {
    @Published public private(set) var entries: [RuntimeLogEntry] = []

    private let logFileURL: URL?
    private let maxInMemoryEntries: Int
    private let maxFileBytes: Int
    private let fileManager: FileManager

    /// Creates a log store.
    ///
    /// - Parameters:
    ///   - logFileURL: File that receives appended entries; `nil` keeps the store in memory only.
    ///   - maxInMemoryEntries: Number of entries retained for the UI and diagnostics.
    ///   - maxFileBytes: Size at which the log file is rotated before appending.
    ///   - fileManager: File system seam used by tests.
    public init(
        logFileURL: URL? = nil,
        maxInMemoryEntries: Int = 500,
        maxFileBytes: Int = 512 * 1024,
        fileManager: FileManager = .default
    ) {
        self.logFileURL = logFileURL
        self.maxInMemoryEntries = maxInMemoryEntries
        self.maxFileBytes = maxFileBytes
        self.fileManager = fileManager
    }

    /// Records one entry in memory and appends it to the log file.
    ///
    /// The message is redacted here, so both the in-memory history and the file are
    /// safe to share in diagnostics.
    ///
    /// - Parameters:
    ///   - component: Subsystem producing the entry; defaults to `Runtime`.
    ///   - level: Severity label.
    ///   - message: Message text to redact and store.
    public func log(
        component: String = "Runtime",
        level: String,
        message: String
    ) {
        // Redact before both memory retention and disk I/O. Consumers can use
        // the in-memory entries without having to remember a second sanitizer.
        let sanitized = LogRedactor.redact(message)
        let entry = RuntimeLogEntry(level: level, component: component, message: sanitized)
        entries.append(entry)
        if entries.count > maxInMemoryEntries {
            entries.removeFirst(entries.count - maxInMemoryEntries)
        }
        write(entry)
    }

    /// The last 40 Harness `stderr` and `error` messages, oldest first.
    ///
    /// Used by crash diagnostics, which need the child process's own output rather
    /// than the app's.
    public var recentStderr: [String] {
        entries
            .filter { $0.component == "Harness" && ($0.level == "stderr" || $0.level == "error") }
            .suffix(40)
            .map(\.message)
    }

    private func write(_ entry: RuntimeLogEntry) {
        guard let url = logFileURL else { return }
        let line = [
            ISO8601DateFormatter().string(from: entry.timestamp),
            entry.level,
            entry.component,
            entry.message
        ].joined(separator: "\t") + "\n"
        guard let data = line.data(using: .utf8) else { return }
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        rotateIfNeeded(url)
        if fileManager.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func rotateIfNeeded(_ url: URL) {
        // Keep the active file plus four numbered backups; rotation happens
        // before appending so the size limit applies to each active file.
        guard let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > maxFileBytes else { return }
        let previous = url.deletingLastPathComponent()
        for index in (1...4).reversed() {
            let current = previous.appendingPathComponent("\(url.lastPathComponent).\(index)")
            let next = previous.appendingPathComponent("\(url.lastPathComponent).\(index + 1)")
            if fileManager.fileExists(atPath: next.path) {
                try? fileManager.removeItem(at: next)
            }
            if fileManager.fileExists(atPath: current.path) {
                try? fileManager.moveItem(at: current, to: next)
            }
        }
        try? fileManager.moveItem(at: url, to: previous.appendingPathComponent("\(url.lastPathComponent).1"))
    }
}

/// Redacts credential-shaped values before they enter logs or user-visible UI.
public enum LogRedactor {
    /// Redacts sensitive values from arbitrary text.
    ///
    /// - Parameter text: Text to sanitize.
    /// - Returns: The sanitized text.
    public static func redact(_ text: String) -> String {
        var result = text
        let patterns: [(pattern: String, replacement: String)] = [
            (#"\bsk-[A-Za-z0-9][A-Za-z0-9_-]*\b"#, "<redacted>"),
            (#"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#, "<redacted>"),
            (
                #"(?i)(["']?(?:api[_-]?key|authorization|password|passwd|secret|token)["']?\s*[:=]\s*["']?)([^\s,}\]"']+)"#,
                "$1<redacted>"
            )
        ]
        for (pattern, replacement) in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return redactHomeDirectory(in: result)
    }

    /// Keeps logs useful without exposing the user's account name or paths.
    ///
    /// Arbitrary absolute paths are replaced when the output is shared.
    public static func redactPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let redacted = redactHomeDirectory(in: standardized)
        if redacted != standardized {
            return redacted
        }
        return standardized.hasPrefix("/") ? "<redacted-path>" : redact(standardized)
    }

    private static func redactHomeDirectory(in text: String) -> String {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .standardizedFileURL
            .path
        guard home.count > 1 else { return text }

        let escapedHome = NSRegularExpression.escapedPattern(for: home)
        let pattern = "(^|[^A-Za-z0-9._-])\(escapedHome)(?=$|[^A-Za-z0-9._-])"
        return text.replacingOccurrences(
            of: pattern,
            with: "$1~",
            options: .regularExpression
        )
    }
}
