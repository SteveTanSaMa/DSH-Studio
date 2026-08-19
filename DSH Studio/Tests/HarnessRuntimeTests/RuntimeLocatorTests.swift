//
//  RuntimeLocatorTests.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import XCTest
@testable import DeepSeekRuntime

/// Verifies architecture-specific Runtime and Application Support paths.
final class RuntimeLocatorTests: XCTestCase {
    func testArchitectureDirectoryIsDarwinStyle() {
        let arch = RuntimeLocator.architectureDirectory()
        XCTAssertTrue(arch == "darwin-arm64" || arch == "darwin-x64")
    }

    func testNodeExecutablePathUsesArchitectureDirectory() {
        let root = URL(fileURLWithPath: "/tmp/runtime")
        let node = RuntimeLocator.nodeExecutable(root: root, architecture: "darwin-arm64")
        XCTAssertEqual(node.lastPathComponent, "node")
        XCTAssertTrue(node.path.contains("darwin-arm64"))
    }

    func testHarnessEntryUsesArchitectureDirectory() {
        let root = URL(fileURLWithPath: "/tmp/runtime")
        let entry = RuntimeLocator.harnessEntry(root: root, architecture: "darwin-x64")
        XCTAssertTrue(entry.path.contains("harness/darwin-x64/0.1.0-rc.6"))
        XCTAssertTrue(entry.path.hasSuffix("@deepseek-ai/dsh/lib/bin.js"))
    }

    func testApplicationSupportUsesDSHStudioNamespace() {
        let support = RuntimeLocator.applicationSupportDirectory()
        XCTAssertTrue(support?.path.hasSuffix("Application Support/DSH Studio") == true)
        XCTAssertFalse(support?.path.contains("DeepSeek Harness") == true)

        let dshHome = RuntimeLocator.defaultDSHHome()
        XCTAssertTrue(dshHome?.path.hasSuffix("Application Support/DSH Studio/DSH_HOME") == true)
    }
}
