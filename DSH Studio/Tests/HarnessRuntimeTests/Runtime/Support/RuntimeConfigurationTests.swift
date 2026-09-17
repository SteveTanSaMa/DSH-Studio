//
//  RuntimeConfigurationTests.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import XCTest
@testable import DeepSeekRuntime

/// Ensures every Harness launch remains bound to 127.0.0.1.
final class RuntimeConfigurationTests: XCTestCase {
    /// Launch arguments always bind the loopback interface.
    func testRuntimeArgumentsAlwaysBindLoopback() {
        let configuration = RuntimeConfiguration(
            nodeExecutable: URL(fileURLWithPath: "/tmp/node"),
            harnessEntry: URL(fileURLWithPath: "/tmp/bin.js"),
            dshHome: URL(fileURLWithPath: "/tmp/dsh-home"),
            workspace: URL(fileURLWithPath: "/tmp/workspace")
        )

        XCTAssertEqual(configuration.host, "127.0.0.1")
        XCTAssertTrue(configuration.arguments.contains("--no-open"))
        XCTAssertEqual(configuration.arguments[3], "--host")
        XCTAssertEqual(configuration.arguments[4], "127.0.0.1")
        XCTAssertFalse(configuration.arguments.contains("0.0.0.0"))
    }

    /// A named profile is passed through the launcher's profile argument.
    func testNamedProfileUsesLauncherProfileArgument() {
        let configuration = RuntimeConfiguration(
            nodeExecutable: URL(fileURLWithPath: "/tmp/node"),
            harnessEntry: URL(fileURLWithPath: "/tmp/dsh"),
            dshHome: URL(fileURLWithPath: "/tmp/home"),
            workspace: URL(fileURLWithPath: "/tmp/workspace"),
            profileName: "review"
        )

        XCTAssertEqual(
            configuration.arguments,
            ["/tmp/dsh", "--profile", "review", "--no-open", "--host", "127.0.0.1", "--port", "0"]
        )
    }

    /// The child's path puts the bundled pnpm and Node first.
    func testRuntimePathPrioritizesBundledPnpmAndNode() {
        let path = SystemHarnessProcess.runtimePath(
            nodeExecutable: URL(fileURLWithPath: "/runtime/node/bin/node"),
            pnpmExecutable: URL(fileURLWithPath: "/runtime/harness/node_modules/.bin/pnpm"),
            inheritedPath: "/opt/homebrew/bin:/usr/bin"
        )

        XCTAssertEqual(
            path,
            "/runtime/harness/node_modules/.bin:/runtime/node/bin:/opt/homebrew/bin:/usr/bin"
        )
    }
}
