//
//  RuntimeError.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import Foundation

/// Typed startup and runtime failures the UI can display without parsing text.
///
/// Values stay unredacted here; the app layer redacts sensitive details when it
/// renders them for the user (`uiDescription` in the App target).
public enum RuntimeError: Error, Equatable, Sendable {
    /// The Runtime directory does not exist; carries the redacted path.
    case missingRuntime(String)
    /// Installing or validating the Runtime failed; carries the detail.
    case runtimeProvisioningFailed(String)
    /// The installation exists but does not satisfy the contract; carries the detail.
    case invalidRuntime(String)
    /// The bundled Node.js version differs from the expected one.
    case nodeVersionMismatch(expected: String, actual: String)
    /// The installed Harness version differs from the expected one.
    case harnessVersionMismatch(expected: String, actual: String)
    /// The data home could not be prepared or read; carries the detail.
    case dshHomeFailure(String)
    /// Compatibility with the existing data could not be proven.
    case dataCompatibilityUnknown
    /// The existing data uses a format this Runtime cannot read.
    case dataIncompatible
    /// The existing data must be migrated before this Runtime may use it.
    case dataMigrationRequired
    /// The workspace could not be used; carries the detail.
    case workspaceFailure(String)
    /// The child process could not be started; carries the detail.
    case processLaunchFailed(String)
    /// The ready line did not appear in time; carries the timeout used.
    case readyTimeout(TimeInterval)
    /// The health probe never reported the Runtime as ready.
    case healthCheckFailed
    /// The child exited unexpectedly; carries the status and recent stderr lines.
    case processCrashed(exitStatus: Int32, stderr: [String])

    /// An English description of the failure for logs and developer-facing text.
    ///
    /// The App layer's `uiDescription` extension provides the localized string used
    /// in the UI.
    public var localizedDescription: String {
        switch self {
        case .missingRuntime(let path):
            return "Missing runtime: \(path)"
        case .runtimeProvisioningFailed(let detail):
            return "Runtime provisioning failed: \(detail)"
        case .invalidRuntime(let detail):
            return "Invalid runtime: \(detail)"
        case .nodeVersionMismatch(let expected, let actual):
            return "Node version mismatch: expected \(expected), found \(actual)"
        case .harnessVersionMismatch(let expected, let actual):
            return "Harness version mismatch: expected \(expected), found \(actual)"
        case .dshHomeFailure(let detail):
            return "DSH_HOME failure: \(detail)"
        case .dataCompatibilityUnknown:
            return "Runtime data compatibility is unknown"
        case .dataIncompatible:
            return "Runtime data format is incompatible"
        case .dataMigrationRequired:
            return "Runtime data migration is required"
        case .workspaceFailure(let detail):
            return "Workspace failure: \(detail)"
        case .processLaunchFailed(let detail):
            return "Process launch failed: \(detail)"
        case .readyTimeout(let seconds):
            return "Startup timed out after \(Int(seconds))s"
        case .healthCheckFailed:
            return "Health check failed"
        case .processCrashed(let status, _):
            return "Harness process crashed with exit status \(status)"
        }
    }
}
