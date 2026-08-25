//
//  WorkspaceAdmission.swift
//  DSH Studio
//

import Foundation

enum WorkspaceAdmissionError: Error, Equatable, LocalizedError {
    case emptyPath
    case notDirectory
    case notReadable
    case notWritable

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

enum WorkspaceAdmission {
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
