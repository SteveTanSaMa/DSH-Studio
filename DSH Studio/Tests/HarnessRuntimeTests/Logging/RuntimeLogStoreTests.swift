//
//  RuntimeLogStoreTests.swift
//  DSH Studio
//

import Foundation
import XCTest
@testable import DeepSeekLogging

/// Verifies bounded in-memory logging, redaction, and on-disk rotation.
final class RuntimeLogStoreTests: XCTestCase {
    /// In-memory history keeps only the newest entries.
    func testInMemoryHistoryIsBounded() {
        let store = RuntimeLogStore(maxInMemoryEntries: 2)
        store.log(level: "info", message: "first")
        store.log(level: "info", message: "second")
        store.log(level: "info", message: "third")
        XCTAssertEqual(store.entries.map(\.message), ["second", "third"])
    }

    /// Messages are redacted before they are retained.
    ///
    /// The in-memory history feeds diagnostics, so it must never hold raw paths.
    func testMessagesAreRedactedBeforeRetention() {
        let store = RuntimeLogStore()
        let home = NSHomeDirectory()
        store.log(level: "info", message: "reading \(home)/secrets.txt")
        XCTAssertFalse(store.entries[0].message.contains(home))
    }

    /// Crash diagnostics see only Harness failures, oldest first.
    func testRecentStderrKeepsOnlyHarnessFailuresInOrder() {
        let store = RuntimeLogStore()
        store.log(component: "Harness", level: "info", message: "started")
        store.log(component: "Harness", level: "stderr", message: "first failure")
        store.log(component: "Runtime", level: "error", message: "app-level error")
        store.log(component: "Harness", level: "error", message: "second failure")
        XCTAssertEqual(store.recentStderr, ["first failure", "second failure"])
    }

    /// A store without a file URL still keeps the in-memory history.
    func testStoreWithoutFileKeepsHistory() {
        let store = RuntimeLogStore(logFileURL: nil)
        store.log(level: "info", message: "memory only")
        XCTAssertEqual(store.entries.count, 1)
    }

    /// Entries are appended to the log file as tab-separated lines.
    func testEntriesAreAppendedToTheLogFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("runtime.log")

        let store = RuntimeLogStore(logFileURL: url)
        store.log(component: "Runtime", level: "warn", message: "rotating soon")

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\twarn\tRuntime\trotating soon"))
    }

    /// A log file over the size limit is rotated into a numbered backup first.
    func testLogFileRotatesBeforeAppending() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("runtime.log")

        // A one-byte limit makes the second write rotate the first one away.
        let store = RuntimeLogStore(logFileURL: url, maxFileBytes: 1)
        store.log(level: "info", message: "first entry")
        store.log(level: "info", message: "second entry")

        let backup = directory.appendingPathComponent("runtime.log.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        let rotated = try String(contentsOf: backup, encoding: .utf8)
        XCTAssertTrue(rotated.contains("first entry"))
        let active = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(active.contains("second entry"))
    }

    // MARK: - Helpers

    /// Creates an isolated directory for one test.
    ///
    /// - Returns: The created directory.
    /// - Throws: When the directory cannot be created.
    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSHStudio-RuntimeLogStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
