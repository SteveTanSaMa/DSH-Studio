//
//  WorkspaceAdmission.swift
//  DSH Studio
//

import Foundation

/// Reasons a selected workspace is rejected.
enum WorkspaceAdmissionError: Error, Equatable, LocalizedError {
    /// The path is empty after normalization.
    case emptyPath
    /// The path does not exist or is not a directory.
    case notDirectory
    /// The directory cannot be read.
    case notReadable
    /// The directory cannot be written to.
    case notWritable

    /// A localized, user-facing description of the rejection.
    var errorDescription: String? {
        switch self {
        case .emptyPath:
            return "工作区路径为空"
        case .notDirectory:
            return "所选路径不是文件夹"
        case .notReadable:
            return "工作区不可读取"
        case .notWritable:
            return "工作区不可写入"
        }
    }
}

/// Validates workspace directories before the app commits to using one.
///
/// Validation happens on the resolved path, while the URL that is returned and
/// persisted keeps the user's spelling so the displayed path stays recognizable.
enum WorkspaceAdmission {
    /// Validates a directory chosen in the open panel.
    ///
    /// Symlinks are resolved for the checks only: the returned URL is the standardized
    /// original, so the persisted value matches what the user selected.
    ///
    /// - Parameters:
    ///   - url: Directory the user selected.
    ///   - fileManager: File system seam used by tests.
    /// - Returns: The standardized URL to persist.
    /// - Throws: ``WorkspaceAdmissionError`` when the directory is missing, not a
    ///   directory, unreadable, or unwritable.
    static func validateSelectedDirectory(
        _ url: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let candidate = url.standardizedFileURL
        guard !candidate.path.isEmpty else { throw WorkspaceAdmissionError.emptyPath }

        let resolved = candidate.resolvingSymlinksInPath()
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspaceAdmissionError.notDirectory
        }
        guard fileManager.isReadableFile(atPath: resolved.path) else {
            throw WorkspaceAdmissionError.notReadable
        }

        // A selected directory may be empty and need not be writable itself when
        // its parent grants creation rights to Runtime. Check the actual path
        // first, then retain the same normalized URL for persistence.
        if !fileManager.isWritableFile(atPath: resolved.path) {
            throw WorkspaceAdmissionError.notWritable
        }
        return candidate
    }

    /// Re-validates a workspace path read from settings.
    ///
    /// A path that no longer exists is kept when its parent is a writable directory,
    /// because Runtime creates the default workspace on first launch; anything else
    /// is discarded rather than handed to the Runtime.
    ///
    /// - Parameters:
    ///   - path: Stored path, or `nil` when nothing was saved.
    ///   - fileManager: File system seam used by tests.
    /// - Returns: The URL to use, or `nil` when the stored value is unusable.
    static func persistedURL(
        from path: String?,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let path,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        var candidateIsDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: resolvedCandidate.path, isDirectory: &candidateIsDirectory),
           candidateIsDirectory.boolValue,
           fileManager.isReadableFile(atPath: resolvedCandidate.path) {
            return candidate
        }

        // Runtime creates the default workspace on first launch, so preserve a
        // missing but creatable path instead of silently discarding the choice.
        let parent = candidate.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parent.path) else {
            return nil
        }
        let resolvedParent = parent.resolvingSymlinksInPath()
        var parentIsDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: resolvedParent.path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue,
              fileManager.isWritableFile(atPath: resolvedParent.path) else {
            return nil
        }
        return candidate
    }
}
