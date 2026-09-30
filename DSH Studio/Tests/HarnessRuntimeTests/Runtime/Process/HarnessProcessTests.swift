//
//  HarnessProcessTests.swift
//  DSH Studio
//

import Darwin
import Foundation
import XCTest

@testable import DeepSeekRuntime

/// Guards that stopping the Runtime takes the processes Harness forked with it.
///
/// The Runtime contract records that a running Harness may fork a copy of itself: a
/// signal to the process this app started alone leaves that copy behind, reparented to
/// launchd. These cases launch real processes, because reparenting is the behaviour the
/// rule exists for and a fake cannot show it.
final class HarnessProcessTests: XCTestCase {
    private var root: URL!
    /// The fixture launched by the running test.
    private var process: SystemHarnessProcess!
    /// The child the fixture forked, so a failed case cannot leave it behind.
    private var forked: pid_t = 0

    /// Creates an isolated directory for the launcher script and its marker file.
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSHStudio.HarnessProcessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Removes the isolated directory and anything still running in it.
    override func tearDownWithError() throws {
        // A failed case must not leave a process behind; a passing one has nothing
        // left to kill.
        if forked > 0 { kill(forked, SIGKILL) }
        process?.forceTerminate()
        try? FileManager.default.removeItem(at: root)
    }

    /// A graceful stop also stops the copy Harness forked.
    func testGracefulTerminationStopsForkedDescendants() throws {
        forked = try launchFixture(ignoresTermination: false)
        XCTAssertTrue(isRunning(forked), "the fixture forked a child")

        process.terminateGracefully()

        XCTAssertTrue(
            waitUntil { !self.isRunning(self.forked) },
            "a child Harness forked must not outlive the Runtime it belongs to"
        )
    }

    /// The forced stop reaches a descendant that ignored the graceful signal.
    func testForcedTerminationStopsDescendantsThatIgnoreSIGTERM() throws {
        forked = try launchFixture(ignoresTermination: true)
        XCTAssertTrue(isRunning(forked), "the fixture forked a child")

        process.terminateGracefully()
        XCTAssertTrue(isRunning(forked), "the fixture ignores the graceful signal")

        process.forceTerminate()

        XCTAssertTrue(
            waitUntil { !self.isRunning(self.forked) },
            "the forced stop must reach what the graceful one could not"
        )
    }

    /// Launches a stand-in Harness that forks a child and waits for it.
    ///
    /// - Parameter ignoresTermination: Whether the fixture and its child ignore
    ///   `SIGTERM`, which is what the forced stop exists for.
    /// - Returns: The forked child's process identifier.
    /// - Throws: When the fixture cannot be written, launched, or observed.
    private func launchFixture(ignoresTermination: Bool) throws -> pid_t {
        let marker = root.appendingPathComponent("forked.pid")
        let script = root.appendingPathComponent("harness.sh")
        // An ignored disposition is inherited across fork, so the child of a trap
        // fixture ignores `SIGTERM` exactly like the fixture itself.
        let ignore = ignoresTermination ? "trap '' TERM\n" : ""
        try Data("""
        #!/bin/sh
        \(ignore)sleep 60 &
        echo $! > "\(marker.path)"
        wait
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        // The configuration's arguments are `[entry, web, --no-open, …]`, so `sh` runs
        // the script and the Harness flags are unused fixtures.
        let configuration = RuntimeConfiguration(
            nodeExecutable: URL(fileURLWithPath: "/bin/sh"),
            harnessEntry: script,
            dshHome: root,
            workspace: root
        )
        let process = SystemHarnessProcess(configuration: configuration)
        try process.launch()
        self.process = process

        for _ in 0..<250 {
            if let text = try? String(contentsOf: marker, encoding: .utf8),
               let identifier = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               identifier > 0 {
                return identifier
            }
            usleep(20_000)
        }
        XCTFail("the fixture never reported the child it forked")
        return 0
    }

    /// Whether a process is still alive.
    ///
    /// - Parameter identifier: Process identifier to probe.
    /// - Returns: `true` while the process exists.
    private func isRunning(_ identifier: pid_t) -> Bool {
        identifier > 0 && kill(identifier, 0) == 0
    }

    /// Waits for a condition to become true.
    ///
    /// - Parameter condition: Condition to poll.
    /// - Returns: Whether the condition became true.
    private func waitUntil(_ condition: () -> Bool) -> Bool {
        for _ in 0..<250 {
            if condition() { return true }
            usleep(20_000)
        }
        return false
    }
}
