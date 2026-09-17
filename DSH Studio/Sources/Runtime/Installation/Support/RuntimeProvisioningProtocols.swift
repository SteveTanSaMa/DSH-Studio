//
//  RuntimeProvisioningProtocols.swift
//  DSH Studio
//

import Foundation

/// Abstraction around downloading the pinned Node archive.
public protocol RuntimeAssetDownloading: Sendable {
    /// Downloads one pinned artifact to a destination file.
    ///
    /// - Parameters:
    ///   - url: Trusted HTTPS artifact URL.
    ///   - destination: File the artifact is written to.
    /// - Throws: When the download fails or the destination cannot be written.
    func download(from url: URL, to destination: URL) async throws
}

/// Abstraction around the local `tar` and `npm` commands used during setup.
public protocol RuntimeProvisioning: Sendable {
    /// Installation root this provisioner owns.
    var root: URL { get }
    /// Architecture the provisioner installs and validates.
    var architecture: String { get }
    /// Installs the pinned Runtime when it is missing or invalid.
    ///
    /// - Returns: The installed root, architecture, and manifest.
    /// - Throws: ``RuntimeProvisioningError`` when the artifact is unavailable, a
    ///   command fails, or the installation does not validate.
    func provision() async throws -> RuntimeProvisioningResult
}

/// Operations that can inspect, replace, and restore an installed Runtime.
public protocol RuntimeUpdating: RuntimeProvisioning {
    /// Compares the installed Runtime with the release this app pins.
    ///
    /// - Returns: The comparison, including data compatibility and rollback
    ///   availability.
    func versionStatus() -> RuntimeVersionStatus
    /// Installs and activates the pinned release in one step.
    ///
    /// - Returns: The activated root, architecture, and manifest.
    /// - Throws: ``RuntimeProvisioningError`` when preparation, activation, or
    ///   validation fails.
    func update() async throws -> RuntimeProvisioningResult
    /// Restores the previously installed Runtime build.
    ///
    /// - Returns: The restored root, architecture, and manifest.
    /// - Throws: ``RuntimeProvisioningError/rollbackUnavailable`` when there is
    ///   nothing to restore, or ``RuntimeProvisioningError/rollbackFailed(_:)``.
    func rollback() throws -> RuntimeProvisioningResult
}

/// Two-phase Runtime updates.
///
/// Preparation may happen while the current Harness keeps running; activation is
/// the explicit point where the active Runtime is replaced.
public protocol RuntimeCandidateUpdating: RuntimeUpdating {
    /// Downloads and verifies an update without activating it.
    ///
    /// The current Runtime keeps serving traffic while this runs.
    ///
    /// - Returns: The prepared candidate.
    /// - Throws: ``RuntimeProvisioningError`` when the candidate cannot be prepared.
    func prepareUpdate() async throws -> RuntimeProvisioningResult
    /// Activates the prepared candidate, replacing the active Runtime.
    ///
    /// - Returns: The activated root, architecture, and manifest.
    /// - Throws: ``RuntimeProvisioningError`` when nothing was prepared or the
    ///   activation fails.
    func activatePreparedUpdate() throws -> RuntimeProvisioningResult
}

/// Changes the release targeted by the next update.
///
/// Used after a verified remote catalog is discovered. This does not install or
/// activate a Runtime; it only changes the update target.
public protocol RuntimeReleaseUpdating: Sendable {
    /// The release currently targeted by the next update.
    var release: RuntimeReleaseDescriptor { get }
    /// Changes the next update target after a verified catalog was discovered.
    ///
    /// - Parameter release: Verified release to target.
    /// - Throws: ``RuntimeProvisioningError`` when the release cannot be adopted.
    func setRelease(_ release: RuntimeReleaseDescriptor) throws
}

/// Lets the update layer evaluate a release against the data profile in use.
///
/// The Runtime and the data profile stay separate objects even though the
/// production provisioner needs the selected profile ID for status reporting.
public protocol RuntimeDataProfileSelecting: Sendable {
    /// Identifier of the data profile the update will reuse.
    var dataProfileID: String? { get }
    /// Selects the data profile the update layer should evaluate.
    ///
    /// - Parameter id: Profile identifier, or `nil` to clear the selection.
    func setDataProfileID(_ id: String?)
}

