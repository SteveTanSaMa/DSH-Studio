import Foundation
import XCTest
@testable import DeepSeekRuntime

/// Progress cases: what a first launch reports while it installs a Runtime.
///
/// A Runtime artifact is close to 200 MiB, so an installation that reports nothing is
/// indistinguishable from a launch that stopped working.
extension RuntimeProvisionerTests {

    /// The local install reports the download in bytes and every later step by name.
    func testLegacyInstallReportsDownloadProgressAndSteps() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let recorder = ProvisioningProgressRecorder()
        let provisioner = RuntimeProvisioner(
            root: parent.appendingPathComponent("Runtime", isDirectory: true),
            architecture: architecture,
            downloader: FixtureDownloader(
                data: Data("node archive fixture".utf8),
                reportedProgress: [(received: 64, expected: 128)]
            ),
            commandRunner: FixtureCommandRunner(),
            packageLockData: try packageLockData(),
            nodeArchiveSHA256Override: fixtureSHA256
        )
        provisioner.progressHandler = { recorder.record($0) }

        _ = try await provisioner.provision()

        let reports = recorder.reports
        XCTAssertFalse(reports.isEmpty, "an install must report what it is doing")
        XCTAssertEqual(reports.first?.fraction, 0, "the download starts at zero")
        XCTAssertEqual(reports.first?.detail, "正在下载 Node.js…")
        XCTAssertTrue(
            reports.contains { $0.fraction == 0.5 },
            "byte progress is reported as a fraction: \(reports)"
        )
        XCTAssertTrue(
            reports.contains { $0.detail == "正在安装 Harness 依赖…" },
            "the dependency install is named even though it has no percentage: \(reports)"
        )
        XCTAssertTrue(reports.allSatisfy { !$0.detail.isEmpty })
    }

    /// A step that cannot be measured reports no fraction rather than a fabricated one.
    func testUnmeasurableStepsReportNoFraction() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let recorder = ProvisioningProgressRecorder()
        let provisioner = RuntimeProvisioner(
            root: parent.appendingPathComponent("Runtime", isDirectory: true),
            architecture: architecture,
            downloader: FixtureDownloader(
                data: Data("node archive fixture".utf8),
                reportedProgress: []
            ),
            commandRunner: FixtureCommandRunner(),
            packageLockData: try packageLockData(),
            nodeArchiveSHA256Override: fixtureSHA256
        )
        provisioner.progressHandler = { recorder.record($0) }

        _ = try await provisioner.provision()

        let unmeasurable = recorder.reports.filter { $0.fraction == nil }
        XCTAssertFalse(unmeasurable.isEmpty)
        XCTAssertTrue(unmeasurable.allSatisfy { !$0.detail.isEmpty })
    }
}

/// Collects progress reports from a provisioner under test.
///
/// The handler is sendable and may be called from a download queue, so the store is
/// lock-protected.
final class ProvisioningProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RuntimeProvisioningProgress] = []

    /// Every report received so far, in order.
    var reports: [RuntimeProvisioningProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Records one report.
    ///
    /// - Parameter progress: Step reported by the provisioner.
    func record(_ progress: RuntimeProvisioningProgress) {
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }
}
