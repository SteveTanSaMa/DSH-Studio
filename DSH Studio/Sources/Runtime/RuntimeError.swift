//
//  RuntimeError.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import Foundation

/// Typed startup and runtime failures the UI can display without parsing text.
/// Sensitive details are redacted when these values cross into user-visible UI.
public enum RuntimeError: Error, Equatable, Sendable {
    case missingRuntime(String)
    case runtimeProvisioningFailed(String)
    case invalidRuntime(String)
    case nodeVersionMismatch(expected: String, actual: String)
    case harnessVersionMismatch(expected: String, actual: String)
    case dshHomeFailure(String)
    case workspaceFailure(String)
    case processLaunchFailed(String)
    case readyTimeout(TimeInterval)
    case healthCheckFailed
    case processCrashed(exitStatus: Int32, stderr: [String])

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
