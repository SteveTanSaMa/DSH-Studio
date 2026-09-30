//
//  RuntimeAssetDownloader.swift
//  DSH Studio
//

import Foundation

/// The production artifact downloader, backed by `URLSession`.
public struct URLSessionRuntimeAssetDownloader: RuntimeAssetDownloading, Sendable {
    /// Creates a downloader with no shared state.
    public init() {}

    /// Downloads a Runtime artifact to a destination file.
    ///
    /// `URLSession` may follow redirects, so both the requested URL and the final
    /// response URL are checked against the trusted hosts before the archive is moved
    /// into place.
    ///
    /// - Parameters:
    ///   - url: Trusted artifact URL.
    ///   - destination: File the archive is written to.
    /// - Throws: ``RuntimeProvisioningError/downloadFailed(_:)`` when the source is
    ///   untrusted, the response status or redirect target is unexpected, or the file
    ///   cannot be moved.
    public func download(from url: URL, to destination: URL) async throws {
        try await download(from: url, to: destination, onProgress: nil)
    }

    /// Downloads a Runtime artifact, reporting the bytes received.
    ///
    /// A Runtime artifact is close to 200 MiB, so the caller is told how far the
    /// download has come; `URLSession` writes to its own temporary file and the archive
    /// only appears at the destination once the transfer completed.
    ///
    /// - Parameters:
    ///   - url: Trusted artifact URL.
    ///   - destination: File the archive is written to.
    ///   - onProgress: Called with the bytes received and the expected total; `0` means
    ///     the server sent no length. Passing `nil` reports nothing.
    /// - Throws: ``RuntimeProvisioningError/downloadFailed(_:)`` when the source is
    ///   untrusted, the response status or redirect target is unexpected, or the file
    ///   cannot be moved.
    public func download(
        from url: URL,
        to destination: URL,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws {
        // URLSession may follow redirects, so validate both the requested and
        // final response host before moving an archive into staging.
        guard isAllowedSourceURL(url) else {
            throw RuntimeProvisioningError.downloadFailed("Runtime 下载地址不是受信任的官方地址")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 900
        guard let onProgress else {
            try await downloadAndMove(temporarySourceFrom: request, to: destination)
            return
        }
        // A download task with a delegate reports the bytes as they arrive; the
        // delegate writes the finished file straight to the destination, because the
        // session deletes the file it downloaded to as soon as its callback returns.
        let delegate = DownloadProgressDelegate(destination: destination, onProgress: onProgress)
        do {
            let response = try await delegate.run(request: request)
            try validate(response: response)
        } catch {
            // A failure that already describes itself is rethrown as it is.
            if let provisioningError = error as? RuntimeProvisioningError {
                throw provisioningError
            }
            throw RuntimeProvisioningError.downloadFailed(error.localizedDescription)
        }
    }

    /// Downloads with the async form and moves the temporary file into place.
    ///
    /// - Parameters:
    ///   - request: Prepared request for a trusted artifact URL.
    ///   - destination: File the archive is moved to.
    /// - Throws: ``RuntimeProvisioningError/downloadFailed(_:)`` when the response is
    ///   unexpected or the file cannot be moved.
    private func downloadAndMove(temporarySourceFrom request: URLRequest, to destination: URL) async throws {
        let (temporaryURL, response): (URL, URLResponse)
        do {
            (temporaryURL, response) = try await URLSession.shared.download(for: request)
        } catch {
            throw RuntimeProvisioningError.downloadFailed(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RuntimeProvisioningError.downloadFailed("服务器返回了无效 HTTP 状态")
        }
        try validate(response: httpResponse)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            throw RuntimeProvisioningError.downloadFailed(error.localizedDescription)
        }
    }

    /// Rejects a response that did not come from a trusted host or did not succeed.
    ///
    /// - Parameter response: Response returned by the transfer.
    /// - Throws: ``RuntimeProvisioningError/downloadFailed(_:)`` when the status is not
    ///   a success or a redirect left the trusted hosts.
    private func validate(response: HTTPURLResponse) throws {
        guard let finalURL = response.url,
              isAllowedFinalURL(finalURL),
              (200...299).contains(response.statusCode) else {
            throw RuntimeProvisioningError.downloadFailed("服务器返回了无效 HTTP 状态")
        }
    }

    private func isAllowedSourceURL(_ url: URL) -> Bool {
        guard url.scheme == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil else {
            return false
        }
        return url.host == "nodejs.org" || isTrustedGitHubArtifactURL(url)
    }

    private func isAllowedFinalURL(_ url: URL) -> Bool {
        guard url.scheme == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil else {
            return false
        }
        return url.host == "nodejs.org"
            || (url.host == "github.com" && isTrustedGitHubArtifactURL(url))
            || url.host == "release-assets.githubusercontent.com"
    }

    private func isTrustedGitHubArtifactURL(_ url: URL) -> Bool {
        let components = url.path.split(separator: "/")
        return components.count == 6
            && components[0] == "SteveTanSaMa"
            && components[1] == "DSH-Studio-Runtime"
            && components[2] == "releases"
            && components[3] == "download"
            && components[4].hasPrefix("runtime-")
            && components[5].hasPrefix("dsh-runtime-")
            && components[5].hasSuffix(".tar.gz")
    }
}

/// Runs one download task and reports its byte progress.
///
/// `URLSession` asks its task delegate on the session's delegate queue, which is not the
/// main actor, so the report is a plain sendable closure. The session deletes the file it
/// downloaded to as soon as `urlSession(_:downloadTask:didFinishDownloadingTo:)` returns,
/// so the file is moved to the caller's destination inside that callback.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var outcome: Result<HTTPURLResponse, Error>?
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?

    /// Creates a delegate that writes the finished file to one destination.
    ///
    /// - Parameters:
    ///   - destination: File the downloaded archive lands in.
    ///   - onProgress: Called with the bytes received and the expected total.
    init(destination: URL, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    /// Downloads a request and waits for the file to arrive at the destination.
    ///
    /// - Parameter request: Prepared request for a trusted artifact URL.
    /// - Returns: The response that carried the file.
    /// - Throws: Whatever the transfer failed with, or
    ///   ``RuntimeProvisioningError/downloadFailed(_:)`` when the response is not an HTTP
    ///   response.
    func run(request: URLRequest) async throws -> HTTPURLResponse {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            session.downloadTask(with: request).resume()
        }
    }

    /// Forwards one write report to the caller.
    ///
    /// - Parameters:
    ///   - session: Session running the download; unused.
    ///   - downloadTask: Task that wrote bytes; unused.
    ///   - bytesWritten: Bytes written since the previous report; unused.
    ///   - totalBytesWritten: Bytes received so far.
    ///   - totalBytesExpectedToWrite: Expected total, or `0` when unknown.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    /// Moves the finished download to the destination before the session deletes it.
    ///
    /// - Parameters:
    ///   - session: Session running the download; unused.
    ///   - downloadTask: Task that finished downloading.
    ///   - location: Temporary file the session wrote.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw RuntimeProvisioningError.downloadFailed("服务器返回了无效 HTTP 状态")
            }
            lock.lock()
            outcome = .success(response)
            lock.unlock()
        } catch {
            lock.lock()
            outcome = .failure(error)
            lock.unlock()
        }
    }

    /// Resumes the waiting caller once the task is done.
    ///
    /// - Parameters:
    ///   - session: Session running the download; unused.
    ///   - task: Task that completed; unused.
    ///   - error: Failure reported by the session, when the transfer did not finish.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let result = outcome ?? .failure(error ?? RuntimeProvisioningError.downloadFailed("Runtime 下载已中断"))
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
