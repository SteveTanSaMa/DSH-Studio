//
//  RuntimeCrashReportStoreTests.swift
//  DSH Studio
//

import XCTest
@testable import DeepSeekLogging
@testable import DeepSeekRuntime

/// Guards the bounded, redacted crash-report storage contract.
final class RuntimeCrashReportStoreTests: XCTestCase {
    /// A report includes the useful process context without leaking credentials.
    func testWriteRedactsSensitiveOutputAndPreservesContext() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-crash-report-(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RuntimeCrashReportStore(directoryURL: directory)
        let configuration = RuntimeConfiguration(
            nodeExecutable: URL(fileURLWithPath: "/tmp/node"),
            harnessEntry: URL(fileURLWithPath: "/tmp/harness/index.js"),
            dshHome: URL(fileURLWithPath: "/tmp/dsh-home"),
            workspace: URL(fileURLWithPath: "/tmp/workspace"),
            expectedNodeVersion: "24.19.0",
            expectedHarnessVersion: "0.1.1"
        )
        let url = store.write(
            status: 7,
            state: .crashed,
            generation: 3,
            processID: 123,
            configuration: configuration,
            nodeVersion: "24.19.0",
            harnessVersion: "0.1.1",
            stderr: ["apiKey=sk-secret123 Authorization: Bearer abc.def"],
            logs: [RuntimeLogEntry(level: "error", component: "Harness", message: "token=secret")],
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertNotNil(url)
        let report = try String(contentsOf: try XCTUnwrap(url), encoding: .utf8)
        XCTAssertTrue(report.contains("exit status: 7"))
        XCTAssertTrue(report.contains("generation: 3"))
        XCTAssertTrue(report.contains("process id: 123"))
        XCTAssertTrue(report.contains("<redacted>"))
        XCTAssertFalse(report.contains("sk-secret123"))
        XCTAssertFalse(report.contains("abc.def"))
    }

    /// Retention keeps the newest twelve reports and removes older reports.
    func testRetentionPrunesOlderReports() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-crash-retention-(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RuntimeCrashReportStore(directoryURL: directory)
        let configuration = RuntimeConfiguration(
            nodeExecutable: URL(fileURLWithPath: "/tmp/node"),
            harnessEntry: URL(fileURLWithPath: "/tmp/harness/index.js"),
            dshHome: URL(fileURLWithPath: "/tmp/dsh-home"),
            workspace: URL(fileURLWithPath: "/tmp/workspace")
        )

        for index in 0..<15 {
            _ = store.write(
                status: Int32(index),
                state: .crashed,
                generation: index,
                processID: nil,
                configuration: configuration,
                nodeVersion: nil,
                harnessVersion: nil,
                stderr: [],
                logs: [],
                date: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let reports = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        XCTAssertEqual(reports.filter { $0.pathExtension == "log" }.count, 12)
    }
}
