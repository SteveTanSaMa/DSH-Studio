//
//  RuntimeDownloadResume.swift
//  DSH Studio
//

import Foundation

/// What one resumed transfer does with the bytes the server sent.
public enum RuntimeDownloadResumeOutcome: Equatable, Sendable {
    /// The server sent only the missing tail: append it to the partial file.
    case append
    /// The server sent the whole artifact: the partial file is replaced.
    case replace
}

/// The rule that decides whether a partial download can be continued.
///
/// Resume is only safe when the server answers a ranged request with a partial body; any
/// other answer means the bytes on disk cannot be trusted as a prefix, and the transfer
/// either starts over or fails so the caller can verify what it has. Nothing here decides
/// integrity: the artifact is always checked against the catalog's SHA-256 afterwards.
public enum RuntimeDownloadResume {
    /// Decides what a resumed transfer does with its response.
    ///
    /// - Parameters:
    ///   - partialBytes: Size of the partial file the request asked to continue from.
    ///   - statusCode: HTTP status the server answered with.
    /// - Returns: The outcome, or `nil` when the transfer cannot be continued and the
    ///   caller has to fall back to verifying or discarding the partial file.
    public static func outcome(partialBytes: Int64, statusCode: Int) -> RuntimeDownloadResumeOutcome? {
        guard partialBytes > 0 else { return .replace }
        switch statusCode {
        case 206:
            return .append
        case 200:
            return .replace
        default:
            return nil
        }
    }

    /// The byte range header that continues a partial download.
    ///
    /// - Parameter partialBytes: Bytes already on disk.
    /// - Returns: The `Range` header value, or `nil` when the download starts from zero.
    public static func rangeHeader(partialBytes: Int64) -> String? {
        partialBytes > 0 ? "bytes=\(partialBytes)-" : nil
    }
}
