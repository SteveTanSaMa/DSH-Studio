//
//  SessionLogExport.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import Foundation

/// Small host-side bridge for suppressing the Harness-owned browser download
/// feedback modal when the native shell takes over the download.
public enum SessionLogExportWebBridge {
    public static let interceptDialogScript = #"""
    (() => {
      if (window.__deepseekStudioSessionExportInterceptInstalled) return;
      window.__deepseekStudioSessionExportInterceptInstalled = true;

      const hiddenSelector = [
        '[role="dialog"][aria-label="正在导出 Session"]',
        '[role="dialog"][aria-label="Session 导出已开始下载"]',
        '[role="dialog"][aria-label="Exporting Session"]',
        '[role="dialog"][aria-label="Session download started"]',
      ].join(", ");
      const dismissSelector = [
        '[role="dialog"][aria-label="Session 导出已开始下载"]',
        '[role="dialog"][aria-label="Session download started"]',
      ].join(", ");
      const modalRootSelector = [
        '[role="presentation"]:has(> [role="dialog"][aria-label="正在导出 Session"])',
        '[role="presentation"]:has(> [role="dialog"][aria-label="Session 导出已开始下载"])',
        '[role="presentation"]:has(> [role="dialog"][aria-label="Exporting Session"])',
        '[role="presentation"]:has(> [role="dialog"][aria-label="Session download started"])',
      ].join(", ");
      const feedbackTitles = new Set([
        "正在导出 Session",
        "Session 导出已开始下载",
        "Exporting Session",
        "Session download started",
      ]);
      const successTitles = new Set([
        "Session 导出已开始下载",
        "Session download started",
      ]);
      const closeLabels = ["关闭", "Close"];

      // Hide the feedback synchronously at insertion time so it cannot flash
      // before React's close-button handler runs. The outer presentation node
      // must be hidden too because it owns the full-viewport mask.
      const style = document.createElement("style");
      style.dataset.deepseekStudioSessionExportInterception = "true";
      style.textContent = `${hiddenSelector}, ${modalRootSelector} { display: none !important; }`;

      const attachStyle = () => {
        const parent = document.head || document.documentElement;
        if (parent && !style.isConnected) parent.appendChild(style);
      };

      const dismiss = (dialog) => {
        if (dialog.dataset.deepseekStudioSessionExportDismissed === "true") return;
        dialog.dataset.deepseekStudioSessionExportDismissed = "true";
        dialog.style.setProperty("display", "none", "important");
        const modalRoot = dialog.closest('[role="presentation"]');
        modalRoot?.style.setProperty("display", "none", "important");
        const button = Array.from(dialog.querySelectorAll("button")).find((candidate) => {
          const label = (candidate.getAttribute("aria-label") || "").trim();
          const text = (candidate.textContent || "").trim();
          return closeLabels.includes(label) || closeLabels.includes(text);
        });
        if (button) button.click();
      };

      const conceal = (dialog) => {
        dialog.style.setProperty("display", "none", "important");
        const modalRoot = dialog.closest('[role="presentation"]');
        modalRoot?.style.setProperty("display", "none", "important");
      };

      const scan = () => {
        attachStyle();
        document.querySelectorAll('[role="dialog"]').forEach((dialog) => {
          const title = (dialog.getAttribute("aria-label") || "").trim();
          if (!feedbackTitles.has(title)) return;
          conceal(dialog);
          if (successTitles.has(title)) dismiss(dialog);
        });
        // Keep the selector path as a fallback for a dialog whose title is
        // assigned after its first render.
        document.querySelectorAll(dismissSelector).forEach(dismiss);
      };

      const observer = new MutationObserver(scan);
      const start = () => {
        const root = document.documentElement;
        if (!root) {
          document.addEventListener("DOMContentLoaded", start, { once: true });
          return;
        }
        observer.observe(root, {
          attributes: true,
          attributeFilter: ["aria-label"],
          childList: true,
          subtree: true,
        });
        scan();
      };

      attachStyle();
      start();
    })();
    """#
}

// The preparation dialog is hidden but not closed so a failed HEAD request can
// still transition it into Harness's visible error state.

public enum SessionLogExportError: Error, Equatable, LocalizedError, Sendable {
    case runtimeUnavailable
    case invalidBaseURL
    case emptySessionID
    case transport(String)
    case invalidResponse
    case httpStatus(Int, String)
    case emptyResponse
    case notZIP
    case stagingFailed(String)
    case saveFailed(String)

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

public struct SessionLogTemporaryDownload: Sendable {
    public let fileURL: URL
    public let statusCode: Int?

    public init(fileURL: URL, statusCode: Int?) {
        self.fileURL = fileURL
        self.statusCode = statusCode
    }
}

public struct URLSessionSessionLogDownloadTransport: Sendable {
    public init() {}

    public func download(_ request: URLRequest) async throws -> SessionLogTemporaryDownload {
        let (fileURL, response) = try await URLSession.shared.download(for: request)
        return SessionLogTemporaryDownload(
            fileURL: fileURL,
            statusCode: (response as? HTTPURLResponse)?.statusCode
        )
    }
}

/// Stages and atomically commits the ZIP returned by the Harness download API.
public final class SessionLogDownloadClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> SessionLogTemporaryDownload

    private let transport: Transport
    private let fileManager: FileManager
    private let temporaryDirectory: URL

    public init(
        transport: @escaping Transport = { request in
            try await URLSessionSessionLogDownloadTransport().download(request)
        },
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.transport = transport
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
    }

    public func stage(sessionID: String, baseURL: URL) async throws -> URL {
        // Keep the URLSession temporary file until its ZIP signature is known;
        // only then move it into the app-owned staging directory.
        let url = try SessionLogExport.exportURL(baseURL: baseURL, sessionID: sessionID)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 300
        request.setValue("application/zip", forHTTPHeaderField: "Accept")

        let downloaded: SessionLogTemporaryDownload
        do {
            downloaded = try await transport(request)
        } catch let error as SessionLogExportError {
            throw error
        } catch {
            throw SessionLogExportError.transport(error.localizedDescription)
        }
        defer { removeIfPresent(downloaded.fileURL) }

        guard let statusCode = downloaded.statusCode, (200...299).contains(statusCode) else {
            if let statusCode = downloaded.statusCode {
                throw SessionLogExportError.httpStatus(statusCode, responseDetail(at: downloaded.fileURL))
            }
            throw SessionLogExportError.invalidResponse
        }
        guard fileManager.fileExists(atPath: downloaded.fileURL.path) else {
            throw SessionLogExportError.emptyResponse
        }
        if let size = try? fileManager.attributesOfItem(atPath: downloaded.fileURL.path)[.size] as? NSNumber,
           size.int64Value == 0 {
            throw SessionLogExportError.emptyResponse
        }
        guard isZIP(at: downloaded.fileURL) else {
            throw SessionLogExportError.notZIP
        }

        do {
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            let stagedURL = temporaryDirectory.appendingPathComponent(
                ".dsh-session-\(UUID().uuidString).partial.zip"
            )
            try fileManager.moveItem(at: downloaded.fileURL, to: stagedURL)
            return stagedURL
        } catch {
            throw SessionLogExportError.stagingFailed(error.localizedDescription)
        }
    }

    public func commit(stagedURL: URL, to destinationURL: URL) throws {
        // Copy into a sibling partial file first so a failed save never leaves
        // a truncated archive at the user's final path.
        guard fileManager.fileExists(atPath: stagedURL.path) else {
            throw SessionLogExportError.saveFailed("临时文件不存在")
        }
        let parent = destinationURL.deletingLastPathComponent()
        let partialDestination = parent.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).partial"
        )
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            try fileManager.copyItem(at: stagedURL, to: partialDestination)
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: partialDestination,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: partialDestination, to: destinationURL)
            }
            removeIfPresent(stagedURL)
        } catch {
            removeIfPresent(partialDestination)
            throw SessionLogExportError.saveFailed(error.localizedDescription)
        }
    }

    public func discard(stagedURL: URL) {
        removeIfPresent(stagedURL)
    }

    private func isZIP(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let signature = handle.readData(ofLength: 4)
        guard signature.count == 4 else { return false }
        let bytes = [UInt8](signature)
        return bytes == [0x50, 0x4B, 0x03, 0x04]
            || bytes == [0x50, 0x4B, 0x05, 0x06]
            || bytes == [0x50, 0x4B, 0x07, 0x08]
    }

    private func responseDetail(at url: URL) -> String {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data.prefix(512), encoding: .utf8) else {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func removeIfPresent(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }
}
