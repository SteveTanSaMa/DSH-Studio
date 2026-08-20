//
//  RuntimeArchiveValidation.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import Foundation

/// Checks archive member names before an untrusted download is extracted.
///
/// Runtime archives are produced by the project builder and are additionally
/// protected by a SHA-256 pin. This boundary check is still required because
/// tar path traversal must never be allowed to escape the staging directory.
public enum RuntimeArchiveListingValidator {
    private static let allowedRootDirectories = ["node", "harness"]

    public static func validate(_ listing: String) throws {
        var foundManifest = false
        var foundNodeDirectory = false
        var foundHarnessDirectory = false

        for rawLine in listing.split(whereSeparator: \.isNewline) {
            let rawPath = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawPath.isEmpty else { continue }

            let path = normalizedPath(rawPath)
            guard !path.isEmpty,
                  !path.hasPrefix("/"),
                  !path.contains("\\") else {
                throw RuntimeProvisioningError.runtimeValidationFailed(
                    "Runtime artifact 包含不安全的路径"
                )
            }

            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.contains(".."),
                  !components.contains(where: { $0.isEmpty }) else {
                throw RuntimeProvisioningError.runtimeValidationFailed(
                    "Runtime artifact 包含路径穿越"
                )
            }

            if path == "manifest.json" {
                foundManifest = true
                continue
            }

            guard let first = components.first.map(String.init),
                  allowedRootDirectories.contains(first) else {
                throw RuntimeProvisioningError.runtimeValidationFailed(
                    "Runtime artifact 包含未授权文件"
                )
            }
            if first == "node" {
                foundNodeDirectory = true
            } else if first == "harness" {
                foundHarnessDirectory = true
            }
        }

        guard foundManifest, foundNodeDirectory, foundHarnessDirectory else {
            throw RuntimeProvisioningError.runtimeValidationFailed(
                "Runtime artifact 缺少必要目录"
            )
        }
    }

    private static func normalizedPath(_ rawPath: String) -> String {
        var path = rawPath
        while path.hasPrefix("./") {
            path.removeFirst(2)
        }
        while path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
