//
//  RuntimeLocator+Validation.swift
//  DSH Studio
//

import Foundation

/// Validation helpers for Runtime installations.
///
/// Every check treats the installation manifest as the publication marker: a
/// missing or mismatched manifest makes the directory unusable, no matter what
/// executables it contains.
extension RuntimeLocator {
    /// The single retained previous installation used by the rollback path.
    public static func rollbackRoot(root: URL) -> URL {
        root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent).backup", isDirectory: true)
    }

    /// Directory for a candidate installation awaiting explicit activation.
    ///
    /// Candidates stay outside the active Runtime directory until the user
    /// activates them.
    public static func candidateRoot(root: URL, runtimeVersion: String) -> URL {
        if root.deletingLastPathComponent().lastPathComponent == "Runtimes",
           isSafeRuntimeVersion(runtimeVersion) {
            return root.deletingLastPathComponent()
                .appendingPathComponent(runtimeVersion, isDirectory: true)
        }
        let safeVersion = runtimeVersion.map { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "." || character == "-" || character == "_")
                ? character
                : "_"
        }
        return root.deletingLastPathComponent()
            .appendingPathComponent(".Runtime-candidate-\(String(safeVersion))", isDirectory: true)
    }

    /// Whether a version string may be used as a directory name.
    ///
    /// - Parameter value: Candidate version, for example `0.1.1-rc.2-ver1`.
    /// - Returns: `true` for a non-empty name of ASCII letters, digits, `.`, `-`, and
    ///   `_` that is not `.` or `..`.
    public static func isSafeRuntimeVersion(_ value: String) -> Bool {
        value != "." && value != ".."
            && !value.isEmpty && value.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_")
            }
    }

    /// Reads the installation manifest for a Runtime root.
    ///
    /// - Parameter root: Runtime root directory.
    /// - Returns: The decoded manifest, or `nil` when it is missing or malformed.
    public static func installationManifest(root: URL) -> RuntimeInstallationManifest? {
        guard let data = try? Data(contentsOf: runtimeManifestURL(root: root)) else {
            return nil
        }
        return try? JSONDecoder().decode(RuntimeInstallationManifest.self, from: data)
    }

    /// Whether a Runtime root holds the complete installation this app expects.
    ///
    /// The manifest, the executables, and the dependency versions must all match.
    /// When `expectedRelease` is supplied every pinned field is compared with it,
    /// otherwise the app's compiled-in release is used.
    ///
    /// - Parameters:
    ///   - root: Runtime root to validate.
    ///   - architecture: Architecture the installation must target.
    ///   - fileManager: File system seam used by tests.
    ///   - expectedNodeVersion: Node.js version the installation must report.
    ///   - expectedHarnessVersion: Harness version the installation must contain.
    ///   - expectedPnpmVersion: pnpm version the installation must contain.
    ///   - expectedNodeSHA256: Node archive checksum to require, overriding the release.
    ///   - expectedRelease: Release every pinned field is compared against.
    /// - Returns: `true` when the root is a complete, matching installation.
    public static func isComplete(
        root: URL,
        architecture: String = architectureDirectory(),
        fileManager: FileManager = .default,
        expectedNodeVersion: String = RuntimeRelease.nodeVersion,
        expectedHarnessVersion: String = harnessVersion,
        expectedPnpmVersion: String = RuntimeRelease.pnpmVersion,
        expectedNodeSHA256: String? = nil,
        expectedRelease: RuntimeReleaseDescriptor? = nil
    ) -> Bool {
        // The manifest is the publication marker. Validate it before trusting
        // the executable and dependency tree below the Runtime root.
        guard let manifest = installationManifest(root: root),
              manifest.schemaVersion == RuntimeInstallationManifest.currentSchemaVersion,
              manifest.architecture == architecture,
              !manifest.nodeSHA256.isEmpty,
              !manifest.harnessPackageIntegrity.isEmpty,
              !manifest.pnpmPackageIntegrity.isEmpty,
              fileManager.isExecutableFile(atPath: nodeExecutable(root: root, architecture: architecture).path),
              fileManager.fileExists(atPath: harnessEntry(root: root, architecture: architecture, harnessVersion: expectedHarnessVersion).path),
              fileManager.isExecutableFile(atPath: pnpmExecutable(root: root, architecture: architecture, harnessVersion: expectedHarnessVersion).path),
              nodeVersion(nodeExecutable: nodeExecutable(root: root, architecture: architecture)) == expectedNodeVersion,
              packageJSONVersion(at: harnessEntry(root: root, architecture: architecture, harnessVersion: expectedHarnessVersion)) == expectedHarnessVersion,
              packageJSONVersion(atPackageURL: pnpmPackageJSON(root: root, architecture: architecture, harnessVersion: expectedHarnessVersion)) == expectedPnpmVersion else {
            return false
        }
        if let expectedRelease {
            let expectedNodeSHA256 = expectedNodeSHA256 ?? expectedRelease.nodeArchiveSHA256
            return manifest.architecture == expectedRelease.architecture
                && manifest.runtimeVersion == expectedRelease.runtimeVersion
                && manifest.nodeVersion == expectedRelease.nodeVersion
                && manifest.harnessVersion == expectedRelease.harnessVersion
                && manifest.pnpmVersion == expectedRelease.pnpmVersion
                && manifest.nodeSHA256 == expectedNodeSHA256
                && manifest.harnessPackageIntegrity == expectedRelease.harnessPackageIntegrity
                && manifest.pnpmPackageIntegrity == expectedRelease.pnpmPackageIntegrity
                && manifest.dataFormat == expectedRelease.dataFormat
        }
        return manifest.runtimeVersion == RuntimeRelease.runtimeVersion
            && manifest.nodeSHA256 == (expectedNodeSHA256 ?? RuntimeRelease.nodeArchiveSHA256(architecture: architecture))
            && manifest.harnessPackageIntegrity == RuntimeRelease.harnessPackageIntegrity
            && manifest.pnpmVersion == expectedPnpmVersion
            && manifest.pnpmPackageIntegrity == RuntimeRelease.pnpmPackageIntegrity
    }

    /// Validates a complete installation of any release.
    ///
    /// The current app release is not required, which is what makes an older
    /// backup eligible for rollback.
    public static func isCompleteInstallation(
        root: URL,
        architecture: String = architectureDirectory(),
        fileManager: FileManager = .default
    ) -> Bool {
        guard let manifest = installationManifest(root: root),
              manifest.schemaVersion == RuntimeInstallationManifest.currentSchemaVersion,
              manifest.architecture == architecture,
              !manifest.nodeSHA256.isEmpty,
              !manifest.harnessPackageIntegrity.isEmpty,
              !manifest.pnpmPackageIntegrity.isEmpty,
              fileManager.isExecutableFile(atPath: nodeExecutable(root: root, architecture: architecture).path),
              fileManager.fileExists(atPath: harnessEntry(root: root, architecture: architecture, harnessVersion: manifest.harnessVersion).path),
              fileManager.isExecutableFile(atPath: pnpmExecutable(root: root, architecture: architecture, harnessVersion: manifest.harnessVersion).path),
              nodeVersion(nodeExecutable: nodeExecutable(root: root, architecture: architecture)) == manifest.nodeVersion,
              packageJSONVersion(at: harnessEntry(root: root, architecture: architecture, harnessVersion: manifest.harnessVersion)) == manifest.harnessVersion,
              packageJSONVersion(atPackageURL: pnpmPackageJSON(root: root, architecture: architecture, harnessVersion: manifest.harnessVersion)) == manifest.pnpmVersion else {
            return false
        }
        return true
    }
}
