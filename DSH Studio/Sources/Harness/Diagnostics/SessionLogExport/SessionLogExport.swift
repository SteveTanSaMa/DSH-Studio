//
//  SessionLogExport.swift
//  DSH Studio
//

import Foundation

// The preparation dialog is hidden but not closed so a failed HEAD request can
// still transition it into Harness's visible error state.

/// Failures raised while exporting one Harness session log.
///
/// Associated values carry raw detail; the user-facing sentence is produced by
/// ``errorDescription``.
public enum SessionLogExportError: Error, Equatable, LocalizedError, Sendable {
    /// Harness is not running, so no export route is reachable.
    case runtimeUnavailable
    /// The Runtime's ready URL is not an allowed loopback URL.
    case invalidBaseURL
    /// The caller supplied an empty session identifier.
    case emptySessionID
    /// The download failed before a response arrived; carries the detail.
    case transport(String)
    /// The response was not an HTTP response.
    case invalidResponse
    /// Harness answered with a non-success status and an optional body excerpt.
    case httpStatus(Int, String)
    /// The download produced an empty file.
    case emptyResponse
    /// The downloaded body is not a ZIP archive.
    case notZIP
    /// The download could not be moved into app-owned staging.
    case stagingFailed(String)
    /// The staged archive could not be written to the chosen destination.
    case saveFailed(String)

    /// A localized, user-facing description of the failure.
    public var errorDescription: String? {
        switch self {
        case .runtimeUnavailable:
            return "Harness Runtime 尚未启动"
        case .invalidBaseURL:
            return "Harness Runtime 地址不可用"
        case .emptySessionID:
            return "Session ID 为空，无法导出日志"
        case .transport(let detail):
            return "Session log 下载失败：\(detail)"
        case .invalidResponse:
            return "Session log 返回了无效响应"
        case .httpStatus(let status, let detail):
            return detail.isEmpty ? "Session log 导出失败（HTTP \(status)）" : "Session log 导出失败（HTTP \(status)）：\(detail)"
        case .emptyResponse:
            return "Session log 返回为空文件"
        case .notZIP:
            return "Session log 返回内容不是 ZIP 文件"
        case .stagingFailed(let detail):
            return "无法准备 Session log 文件：\(detail)"
        case .saveFailed(let detail):
            return "无法保存 Session log 文件：\(detail)"
        }
    }
}

/// Native contract for exporting one Harness session log.
///
/// The URL and filename rules deliberately mirror Harness's own browser export so
/// the native and web paths produce identical archives.
public enum SessionLogExport {
    /// Builds the same loopback API URL used by Harness's browser export.
    public static func exportURL(baseURL: URL, sessionID: String) throws -> URL {
        guard !sessionID.isEmpty else { throw SessionLogExportError.emptySessionID }
        guard HarnessURLPolicy.isAllowedLoopback(baseURL) else {
            throw SessionLogExportError.invalidBaseURL
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw SessionLogExportError.invalidBaseURL
        }
        components.path = "/api/session.export"
        components.queryItems = [
            URLQueryItem(name: "sessionId", value: sessionID),
            URLQueryItem(name: "includeDescendants", value: "true")
        ]
        components.fragment = nil
        guard let url = components.url else { throw SessionLogExportError.invalidBaseURL }
        return url
    }

    /// Produces a filesystem-safe filename without allowing path traversal.
    public static func filename(sessionID: String) -> String {
        // Keep the native filename contract identical to the official web client.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let safe = sessionID.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        return "dsh-session-\(safe.isEmpty ? "session" : safe).zip"
    }
}
