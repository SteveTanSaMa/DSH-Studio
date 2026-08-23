//
//  SessionLogDownload.swift
//  DSH Studio
//

import Foundation

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
