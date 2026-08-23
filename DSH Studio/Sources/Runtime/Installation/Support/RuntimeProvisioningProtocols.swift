//
//  RuntimeProvisioningProtocols.swift
//  DSH Studio
//

import Foundation

/// Abstraction around downloading the pinned Node archive.
public protocol RuntimeAssetDownloading: Sendable {
    func download(from url: URL, to destination: URL) async throws
}

/// Abstraction around the local `tar` and `npm` commands used during setup.
public protocol RuntimeProvisioning: Sendable {
    var root: URL { get }
    var architecture: String { get }
    func provision() async throws -> RuntimeProvisioningResult
}

/// Operations that can inspect, replace, and restore an installed Runtime.
public protocol RuntimeUpdating: RuntimeProvisioning {
    func versionStatus() -> RuntimeVersionStatus
    func update() async throws -> RuntimeProvisioningResult
    func rollback() throws -> RuntimeProvisioningResult
}

/// Two-phase Runtime updates. Preparation may happen while the current
/// Harness keeps running; activation is the explicit point where the active
/// Runtime is replaced.
public protocol RuntimeCandidateUpdating: RuntimeUpdating {
    func prepareUpdate() async throws -> RuntimeProvisioningResult
    func activatePreparedUpdate() throws -> RuntimeProvisioningResult
}

/// Replaces the release selected by an already-running app after a verified
/// remote catalog has been discovered. This does not install or activate a
/// Runtime; it only changes the next update target.
public protocol RuntimeReleaseUpdating: Sendable {
    var release: RuntimeReleaseDescriptor { get }
    func setRelease(_ release: RuntimeReleaseDescriptor) throws
}

/// Lets the Runtime update layer evaluate a release against the data profile
/// that the app is about to use. The Runtime and data profile remain separate
/// objects even though the production provisioner needs the selected profile ID
/// for status reporting.
public protocol RuntimeDataProfileSelecting: Sendable {
    var dataProfileID: String? { get }
    func setDataProfileID(_ id: String?)
}

