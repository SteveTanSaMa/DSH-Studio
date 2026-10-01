//
//  RuntimeProvisioningProtocols.swift
//  DSH Studio
//

import Foundation

/// Coarse progress of one Runtime installation.
///
/// A Runtime artifact is close to 200 MiB, so a first launch spends minutes
/// downloading before anything can start. This is what the loading surface and the
/// log report while that happens.
public struct RuntimeProvisioningProgress: Equatable, Sendable {
    /// Completion in `0...1`, or `nil` while the current step cannot be measured.
    ///
    /// Steps such as extracting an archive or running the dependency install have no
    /// meaningful percentage, and reporting a fabricated one would make the surface
    /// look further along than it is.
    public let fraction: Double?
    /// User-facing description of the current step.
    public let detail: String

    /// Creates one progress report.
    ///
    /// - Parameters:
    ///   - fraction: Completion in `0...1`, or `nil` when the step cannot be measured.
    ///   - detail: User-facing description of the step.
    public init(fraction: Double?, detail: String) {
        self.fraction = fraction
        self.detail = detail
    }
}

/// Abstraction around downloading the pinned Node archive and Runtime artifact.
public protocol RuntimeAssetDownloading: Sendable {
    /// Downloads one pinned artifact to a destination file.
    ///
    /// - Parameters:
    ///   - url: Trusted HTTPS artifact URL.
    ///   - destination: File the artifact is written to.
    /// - Throws: When the download fails or the destination cannot be written.
    func download(from url: URL, to destination: URL) async throws

    /// Downloads one pinned artifact while reporting the bytes received.
    ///
    /// - Parameters:
    ///   - url: Trusted HTTPS artifact URL.
    ///   - destination: File the artifact is written to.
    ///   - onProgress: Called with the bytes received and the expected total; the total
    ///     is `0` when the server sends no length. Passing `nil` reports nothing.
    /// - Throws: When the download fails or the destination cannot be written.
    func download(
        from url: URL,
        to destination: URL,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws

    /// Downloads one pinned artifact, continuing a partial file when the server allows it.
    ///
    /// - Parameters:
    ///   - url: Trusted HTTPS artifact URL.
    ///   - destination: File the artifact is written to.
    ///   - partial: Partial file to continue, when one exists.
    ///   - onProgress: Called with the bytes received and the expected total; the total
    ///     is `0` when the server sends no length. Passing `nil` reports nothing.
    /// - Throws: When the download fails or the destination cannot be written.
    func download(
        from url: URL,
        to destination: URL,
        resumingFrom partial: URL?,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws
}

/// Shared behaviour for downloaders.
public extension RuntimeAssetDownloading {
    /// Reports nothing, for downloaders that cannot measure progress.
    ///
    /// - Parameters:
    ///   - url: Trusted HTTPS artifact URL.
    ///   - destination: File the artifact is written to.
    ///   - onProgress: Ignored.
    /// - Throws: Whatever the plain download throws.
    func download(
        from url: URL,
        to destination: URL,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws {
        try await download(from: url, to: destination)
    }

    /// Starts over, for downloaders that cannot continue a partial file.
    ///
    /// - Parameters:
    ///   - url: Trusted HTTPS artifact URL.
    ///   - destination: File the artifact is written to.
    ///   - partial: Ignored.
    ///   - onProgress: Forwarded to the plain progress download.
    /// - Throws: Whatever the progress download throws.
    func download(
        from url: URL,
        to destination: URL,
        resumingFrom partial: URL?,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws {
        try await download(from: url, to: destination, onProgress: onProgress)
    }
}

/// Abstraction around the local `tar` and `npm` commands used during setup.
public protocol RuntimeProvisioning: AnyObject, Sendable {
    /// Installation root this provisioner owns.
    var root: URL { get }
    /// Architecture the provisioner installs and validates.
    var architecture: String { get }
    /// Receives coarse progress while this provisioner installs.
    ///
    /// The Runtime manager attaches one so the loading surface can report a download
    /// that takes minutes. A provisioner that installs nothing reports nothing, but it
    /// still has to hold the handler: a silently dropped assignment would leave the
    /// surface unable to tell an install apart from a hang.
    var progressHandler: (@Sendable (RuntimeProvisioningProgress) -> Void)? { get set }
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

