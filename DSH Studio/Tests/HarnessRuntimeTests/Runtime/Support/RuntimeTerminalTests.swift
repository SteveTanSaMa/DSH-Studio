import Foundation
import XCTest

@testable import DeepSeekRuntime

/// Guards the generated terminal files and their scoped environment.
final class RuntimeTerminalTests: XCTestCase {
    /// Terminal files are created privately and scoped to the profile.
    func testPrepareCreatesPrivateProfileAwareTerminalFilesWithoutGlobalPathMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSHStudio-RuntimeTerminal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configuration = RuntimeTerminalConfiguration(
            stateDirectory: root.appendingPathComponent("terminal", isDirectory: true),
            nodeExecutable: URL(fileURLWithPath: "/opt/DSH Runtime/bin/node"),
            harnessEntry: URL(fileURLWithPath: "/opt/DSH Runtime/dsh.js"),
            pnpmExecutable: URL(fileURLWithPath: "/opt/DSH Runtime/pnpm.cjs"),
            dshHome: root.appendingPathComponent("DSH_HOME", isDirectory: true),
            workspace: root.appendingPathComponent("workspace with spaces", isDirectory: true),
            profileName: "review"
        )

        let files = try RuntimeTerminalFileGenerator().prepare(configuration: configuration)
        let dsh = try String(contentsOf: files.dshShim, encoding: .utf8)
        let welcome = try String(contentsOf: files.welcomeScript, encoding: .utf8)

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: files.dshShim.path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: files.welcomeScript.path))
        XCTAssertTrue(dsh.contains("default_profile='review'"))
        XCTAssertTrue(dsh.contains("plugin --profile \"$default_profile\""))
        XCTAssertTrue(dsh.contains("/opt/DSH Runtime/bin/node"))
        XCTAssertTrue(welcome.contains("export DSH_HOME='/"))
        XCTAssertTrue(welcome.contains("export PATH='\(files.shimDirectory.path)'"))
        XCTAssertTrue(welcome.contains("cd '\(configuration.workspace.path)'"))
        XCTAssertTrue(welcome.contains("export ZDOTDIR='\(files.stateDirectory.path)'"))
        XCTAssertFalse(welcome.contains("/etc/paths"))
    }

    /// An unsafe profile name or path value is refused.
    func testPrepareRejectsUnsafeProfileAndGeneratedPathValues() {
        let configuration = RuntimeTerminalConfiguration(
            stateDirectory: URL(fileURLWithPath: "/tmp/terminal"),
            nodeExecutable: URL(fileURLWithPath: "/tmp/node"),
            harnessEntry: URL(fileURLWithPath: "/tmp/dsh"),
            pnpmExecutable: nil,
            dshHome: URL(fileURLWithPath: "/tmp/home"),
            workspace: URL(fileURLWithPath: "/tmp/workspace"),
            profileName: "../escape"
        )

        XCTAssertThrowsError(try RuntimeTerminalFileGenerator().prepare(configuration: configuration)) { error in
            XCTAssertEqual(error as? RuntimeTerminalError, .invalidValue("profileName"))
            XCTAssertEqual(
                (error as? RuntimeTerminalError)?.errorDescription,
                "终端配置无效：profileName"
            )
        }
    }

    /// The pnpm shim fails closed when the Runtime provides no pnpm.
    func testPnpmShimFailsClosedWhenRuntimeDoesNotProvidePnpm() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSHStudio-RuntimeTerminal-pnpm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configuration = RuntimeTerminalConfiguration(
            stateDirectory: root.appendingPathComponent("terminal", isDirectory: true),
            nodeExecutable: URL(fileURLWithPath: "/tmp/node"),
            harnessEntry: URL(fileURLWithPath: "/tmp/dsh"),
            pnpmExecutable: nil,
            dshHome: root.appendingPathComponent("home", isDirectory: true),
            workspace: root.appendingPathComponent("workspace", isDirectory: true),
            profileName: "web"
        )

        let files = try RuntimeTerminalFileGenerator().prepare(configuration: configuration)
        let pnpm = try String(contentsOf: files.pnpmShim, encoding: .utf8)
        XCTAssertTrue(pnpm.contains("pnpm is unavailable"))
    }

    /// The DSH shim runs Node with the default profile and a scoped data home.
    func testDshShimExecutesNodeWithDefaultProfileAndScopedHome() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSHStudio-RuntimeTerminal-exec-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let node = root.appendingPathComponent("runtime with spaces/node", isDirectory: false)
        let output = root.appendingPathComponent("invocation.txt", isDirectory: false)
        try FileManager.default.createDirectory(at: node.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fakeNode = """
        #!/bin/sh
        {
          printf 'DSH_HOME=%s\\n' "$DSH_HOME"
          printf 'ARG=%s\\n' "$@"
        } > "$DSH_TEST_OUTPUT"
        """
        try Data(fakeNode.utf8).write(to: node, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node.path)

        let configuration = RuntimeTerminalConfiguration(
            stateDirectory: root.appendingPathComponent("terminal", isDirectory: true),
            nodeExecutable: node,
            harnessEntry: root.appendingPathComponent("runtime/dsh.js", isDirectory: false),
            pnpmExecutable: nil,
            dshHome: root.appendingPathComponent("DSH_HOME", isDirectory: true),
            workspace: root.appendingPathComponent("workspace", isDirectory: true),
            profileName: "review"
        )
        let files = try RuntimeTerminalFileGenerator().prepare(configuration: configuration)

        let process = Process()
        process.executableURL = files.dshShim
        process.arguments = ["plugin", "install", "@example/plugin"]
        var environment = ProcessInfo.processInfo.environment
        environment["DSH_TEST_OUTPUT"] = output.path
        process.environment = environment
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "DSH_HOME=\(configuration.dshHome.path)")
        XCTAssertEqual(
            Array(lines.dropFirst()),
            [
                "ARG=\(configuration.harnessEntry.path)",
                "ARG=plugin",
                "ARG=--profile",
                "ARG=review",
                "ARG=install",
                "ARG=@example/plugin"
            ]
        )
    }
}
