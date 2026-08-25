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
        XCTAssertTrue(entry.path.contains("harness/darwin-x64/0.1.1-rc.2"))
        XCTAssertTrue(entry.path.hasSuffix("@deepseek-ai/dsh/lib/bin.js"))
    }

    func testVersionedRuntimePathsAreSeparatedByRuntimeVersion() {
        let support = URL(fileURLWithPath: "/tmp/dsh-support", isDirectory: true)

        let oldRoot = RuntimeLocator.versionedRuntimeRoot(
            supportDirectory: support,
            runtimeVersion: "2026.08.20.1"
        )
        let newRoot = RuntimeLocator.versionedRuntimeRoot(
            supportDirectory: support,
            runtimeVersion: "2026.08.21.1"
        )

        XCTAssertNotEqual(oldRoot, newRoot)
        XCTAssertTrue(oldRoot?.path.hasSuffix("Runtimes/2026.08.20.1") == true)
        XCTAssertTrue(
            oldRoot.map { RuntimeLocator.isVersionedRuntimeRoot($0, supportDirectory: support) } == true
        )
        XCTAssertEqual(
            oldRoot.map { RuntimeLocator.candidateRoot(root: $0, runtimeVersion: "2026.08.21.1") },
            newRoot
        )
    }

    func testVersionedRuntimeRejectsPathComponents() {
        XCTAssertNil(
            RuntimeLocator.versionedRuntimeRoot(
                supportDirectory: URL(fileURLWithPath: "/tmp/dsh-support", isDirectory: true),
                runtimeVersion: ".."
            )
        )
        XCTAssertFalse(RuntimeLocator.isSafeRuntimeVersion("."))
        XCTAssertFalse(RuntimeLocator.isSafeRuntimeVersion(".."))
    }

    func testApplicationSupportUsesDSHStudioNamespace() {
        let support = RuntimeLocator.applicationSupportDirectory()
        XCTAssertTrue(support?.path.hasSuffix("Application Support/DSH Studio") == true)
        XCTAssertFalse(support?.path.contains("DeepSeek Harness") == true)

        let dshHome = RuntimeLocator.defaultDSHHome()
        XCTAssertTrue(dshHome?.path.hasSuffix("Application Support/DSH Studio/DSH_HOME") == true)
    }

    func makeRuntimeFixture(
        root: URL,
        runtimeVersion: String,
        harnessVersion: String
    ) throws {
        let fileManager = FileManager.default
        let architecture = "darwin-arm64"
        let node = RuntimeLocator.nodeExecutable(root: root, architecture: architecture)
        try fileManager.createDirectory(at: node.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho v24.19.0\n".utf8).write(to: node)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: node.path)

        let harness = RuntimeLocator.harnessEntry(
            root: root,
            architecture: architecture,
            harnessVersion: harnessVersion
        )
        try fileManager.createDirectory(at: harness.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env node\n".utf8).write(to: harness)
        let harnessPackage = RuntimeLocator.harnessRoot(
            root: root,
            architecture: architecture,
            harnessVersion: harnessVersion
        ).appendingPathComponent("node_modules/@deepseek-ai/dsh/package.json")
        try Data("{\"name\":\"@deepseek-ai/dsh\",\"version\":\"\(harnessVersion)\"}".utf8)
            .write(to: harnessPackage)

        let pnpm = RuntimeLocator.pnpmExecutable(
            root: root,
            architecture: architecture,
            harnessVersion: harnessVersion
        )
        try fileManager.createDirectory(at: pnpm.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: pnpm)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: pnpm.path)
        let pnpmPackage = RuntimeLocator.pnpmPackageJSON(
            root: root,
            architecture: architecture,
            harnessVersion: harnessVersion
        )
        try fileManager.createDirectory(at: pnpmPackage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"name\":\"pnpm\",\"version\":\"\(RuntimeRelease.pnpmVersion)\"}".utf8).write(to: pnpmPackage)

        let manifest = RuntimeInstallationManifest(
            runtimeVersion: runtimeVersion,
            architecture: architecture,
            nodeVersion: "24.19.0",
            harnessVersion: harnessVersion,
            nodeSHA256: "node-sha",
            harnessPackageIntegrity: "harness-integrity",
            dataFormat: RuntimeDataFormatDescriptor(id: "sqlite-v1")
        )
        try JSONEncoder().encode(manifest).write(
            to: RuntimeLocator.runtimeManifestURL(root: root),
            options: .atomic
        )
    }
}
