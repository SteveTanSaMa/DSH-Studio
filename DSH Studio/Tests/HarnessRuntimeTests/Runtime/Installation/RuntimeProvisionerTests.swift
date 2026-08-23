//
//  RuntimeProvisionerTests.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import Foundation
import XCTest
@testable import DeepSeekRuntime

/// Verifies pinned downloads, checksums, staging, and cancellation cleanup.
final class RuntimeProvisionerTests: XCTestCase {
    let architecture = "darwin-arm64"
    let fixtureSHA256 = "58d6dca829b124ec89d74c20bc88df55e086531559c841582de076a9157c4bb3"

    func packageLockData() throws -> Data {
        let harnessIntegrity = RuntimeRelease.harnessPackageIntegrity
        let pnpmIntegrity = RuntimeRelease.pnpmPackageIntegrity
        let json = """
        {
          "name": "deepseek-harness-macos-runtime",
          "version": "0.0.1",
          "lockfileVersion": 3,
          "requires": true,
          "packages": {
            "": {
              "name": "deepseek-harness-macos-runtime",
              "version": "0.0.1",
              "dependencies": {
                "@deepseek-ai/dsh": "0.1.0-rc.6",
                "pnpm": "\(RuntimeRelease.pnpmVersion)"
              }
            },
            "node_modules/@deepseek-ai/dsh": {
              "version": "0.1.0-rc.6",
              "resolved": "https://registry.npmjs.org/@deepseek-ai/dsh/-/dsh-0.1.0-rc.6.tgz",
              "integrity": "\(harnessIntegrity)"
            },
            "node_modules/pnpm": {
              "version": "\(RuntimeRelease.pnpmVersion)",
              "resolved": "https://registry.npmjs.org/pnpm/-/pnpm-\(RuntimeRelease.pnpmVersion).tgz",
              "integrity": "\(pnpmIntegrity)"
            }
          }
        }
        """
        return try XCTUnwrap(json.data(using: .utf8))
    }

    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeInstalledFixture(
        root: URL,
        architecture: String,
        nodeVersion: String,
        harnessVersion: String,
        nodeSHA256: String,
        harnessIntegrity: String,
        runtimeVersion: String = RuntimeRelease.runtimeVersion
    ) throws {
        let fileManager = FileManager.default
        let node = RuntimeLocator.nodeExecutable(root: root, architecture: architecture)
        try fileManager.createDirectory(at: node.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho v\(nodeVersion)\n".utf8).write(to: node)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: node.path)

        let entry = RuntimeLocator.harnessEntry(
            root: root,
            architecture: architecture,
            harnessVersion: harnessVersion
        )
        try fileManager.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env node\n".utf8).write(to: entry)
        let package = entry
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("package.json")
        try Data("{\"name\":\"@deepseek-ai/dsh\",\"version\":\"\(harnessVersion)\"}".utf8)
            .write(to: package)

        let pnpmPackage = RuntimeLocator.pnpmPackageJSON(
            root: root,
            architecture: architecture,
            harnessVersion: harnessVersion
        )
        try fileManager.createDirectory(at: pnpmPackage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"name\":\"pnpm\",\"version\":\"\(RuntimeRelease.pnpmVersion)\"}".utf8)
            .write(to: pnpmPackage)
        let pnpmShim = RuntimeLocator.pnpmExecutable(
            root: root,
            architecture: architecture,
            harnessVersion: harnessVersion
        )
        try fileManager.createDirectory(at: pnpmShim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: pnpmShim)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: pnpmShim.path)

        let manifest = RuntimeInstallationManifest(
            runtimeVersion: runtimeVersion,
            architecture: architecture,
            nodeVersion: nodeVersion,
            harnessVersion: harnessVersion,
            nodeSHA256: nodeSHA256,
            harnessPackageIntegrity: harnessIntegrity
        )
        let data = try JSONEncoder().encode(manifest)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: RuntimeLocator.runtimeManifestURL(root: root), options: .atomic)
    }
}
