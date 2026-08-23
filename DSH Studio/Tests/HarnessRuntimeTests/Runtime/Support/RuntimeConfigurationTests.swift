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
    func testRuntimeArgumentsAlwaysBindLoopback() {
        let configuration = RuntimeConfiguration(
            nodeExecutable: URL(fileURLWithPath: "/tmp/node"),
            harnessEntry: URL(fileURLWithPath: "/tmp/bin.js"),
            dshHome: URL(fileURLWithPath: "/tmp/dsh-home"),
            workspace: URL(fileURLWithPath: "/tmp/workspace")
        )

        XCTAssertEqual(configuration.host, "127.0.0.1")
        XCTAssertEqual(configuration.arguments[2], "--host")
        XCTAssertEqual(configuration.arguments[3], "127.0.0.1")
        XCTAssertFalse(configuration.arguments.contains("0.0.0.0"))
    }

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
