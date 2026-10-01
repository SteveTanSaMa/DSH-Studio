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
        try await download(from: url, to: destination, resumingFrom: nil, onProgress: onProgress)
    }

    /// Downloads a Runtime artifact, continuing a partial file when the server allows it.
    ///
    /// The transfer streams to disk instead of buffering, so an interrupted download keeps
    /// everything it already received: on a slow link that prefix is worth minutes, and the
    /// SHA-256 check the caller performs afterwards is what decides whether those bytes are
    /// the right ones. A server that answers a ranged request with the whole artifact simply
    /// replaces the partial file.
    ///
    /// - Parameters:
    ///   - url: Trusted artifact URL.
    ///   - destination: File the archive is written to.
    ///   - partial: Partial file to continue, when one exists.
    ///   - onProgress: Called with the bytes received and the expected total; `0` means the
    ///     server sent no length. Passing `nil` reports nothing.
    /// - Throws: ``RuntimeProvisioningError/downloadFailed(_:)`` when the source is
    ///   untrusted, the response status or redirect target is unexpected, or the file
    ///   cannot be written.
    public func download(
        from url: URL,
        to destination: URL,
        resumingFrom partial: URL?,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws {
        // URLSession may follow redirects, so validate both the requested and
        // final response host before keeping the file.
        guard isAllowedSourceURL(url) else {
            throw RuntimeProvisioningError.downloadFailed("Runtime 下载地址不是受信任的官方地址")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 900
        let resumeBytes = Self.fileSize(at: partial)
        if let header = RuntimeDownloadResume.rangeHeader(partialBytes: resumeBytes) {
            request.setValue(header, forHTTPHeaderField: "Range")
        }
        let delegate = DownloadStreamDelegate(
            partial: partial ?? destination,
            destination: destination,
            resumeBytes: resumeBytes,
            onProgress: onProgress
        )
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

    /// Size of an existing file.
    ///
    /// - Parameter url: File to measure, when one is expected.
    /// - Returns: Size in bytes, or `0` when there is no readable file.
    static func fileSize(at url: URL?) -> Int64 {
        guard let url,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
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

/// Streams one artifact to disk, reporting progress and keeping what arrived.
///
/// A data task is used instead of a download task because the bytes have to reach the file
/// as they arrive: `URLSession` deletes a download task's temporary file whenever the
/// transfer fails, which would throw away an interrupted download's progress. Every chunk
/// is appended under a lock, so a cancel or a crash leaves a usable prefix on disk.
private final class DownloadStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// File that accumulates the bytes; the destination when there is no partial file.
    private let partial: URL
    /// File the completed artifact is moved to.
    private let destination: URL
    /// Bytes the partial file already held when the request was built.
    private let resumeBytes: Int64
    private let onProgress: (@Sendable (Int64, Int64) -> Void)?
    private let lock = NSLock()
    private var handle: FileHandle?
    private var received: Int64 = 0
    /// Bytes the transfer's own count starts from; zero when the file was restarted.
    private var baseBytes: Int64
    private var outcome: Result<HTTPURLResponse, Error>?
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?

    /// Creates a delegate for one transfer.
    ///
    /// - Parameters:
    ///   - partial: File that accumulates the bytes.
    ///   - destination: File the completed artifact lands in.
    ///   - resumeBytes: Bytes the partial file already held.
    ///   - onProgress: Called with the bytes received and the expected total.
    init(
        partial: URL,
        destination: URL,
        resumeBytes: Int64,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) {
        self.partial = partial
        self.destination = destination
        self.resumeBytes = resumeBytes
        self.baseBytes = resumeBytes
        self.onProgress = onProgress
    }

    /// Runs a request and waits for the artifact to arrive at the destination.
    ///
    /// - Parameter request: Prepared request for a trusted artifact URL.
    /// - Returns: The response that carried the artifact.
    /// - Throws: Whatever the transfer failed with.
    func run(request: URLRequest) async throws -> HTTPURLResponse {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try prepareFile()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            session.dataTask(with: request).resume()
        }
    }

    /// Reads the response and decides whether its bytes continue the partial file.
    ///
    /// - Parameters:
    ///   - session: Session running the transfer; unused.
    ///   - dataTask: Task that received the response; unused.
    ///   - response: Response the server sent.
    ///   - completionHandler: Called to let the transfer proceed, or cancelled when the
    ///     bytes on disk cannot be trusted as a prefix.
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(RuntimeProvisioningError.downloadFailed("服务器返回了无效 HTTP 状态")))
            completionHandler(.cancel)
            return
        }
        switch RuntimeDownloadResume.outcome(partialBytes: resumeBytes, statusCode: http.statusCode) {
        case .append:
            completionHandler(.allow)
        case .replace:
            // The server sent the whole artifact even though the request continued a file:
            // the file has to start over, or the answer would be appended to the bytes it
            // already duplicates.
            guard restartFile() else {
                finish(.failure(RuntimeProvisioningError.downloadFailed("Runtime 下载文件无法重置")))
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        case nil:
            // The server neither continued the file nor sent the whole artifact, so the
            // caller verifies or discards what is on disk before trying again.
            finish(.failure(RuntimeProvisioningError.downloadFailed("Runtime 下载无法续传")))
            completionHandler(.cancel)
        }
    }

    /// Appends one chunk to the partial file and reports the running total.
    ///
    /// - Parameters:
    ///   - session: Session running the transfer; unused.
    ///   - dataTask: Task that received the bytes.
    ///   - data: Chunk to append.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let handle = self.handle
        lock.unlock()
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            finish(.failure(error))
            dataTask.cancel()
            return
        }
        lock.lock()
        received += Int64(data.count)
        let total = baseBytes + max(0, dataTask.countOfBytesExpectedToReceive)
        let reported = baseBytes + received
        lock.unlock()
        onProgress?(reported, total)
    }

    /// Moves the finished artifact into place once the task is done.
    ///
    /// - Parameters:
    ///   - session: Session running the transfer; unused.
    ///   - task: Task that completed.
    ///   - error: Failure reported by the session, when the transfer did not finish.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let handle = self.handle
        self.handle = nil
        lock.unlock()
        try? handle?.close()

        if let error {
            // The bytes received so far stay on disk: the next attempt continues from them,
            // and the caller's checksum decides whether they are the right ones.
            finish(.failure(error))
            return
        }
        do {
            guard let response = task.response as? HTTPURLResponse else {
                throw RuntimeProvisioningError.downloadFailed("服务器返回了无效 HTTP 状态")
            }
            if partial != destination {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: partial, to: destination)
            }
            finish(.success(response))
        } catch {
            finish(.failure(error))
        }
    }

    /// Empties the accumulating file so a full answer starts from zero.
    ///
    /// - Returns: Whether the file could be reset.
    private func restartFile() -> Bool {
        lock.lock()
        let handle = self.handle
        received = 0
        baseBytes = 0
        lock.unlock()
        guard let handle else { return false }
        do {
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
            return true
        } catch {
            return false
        }
    }

    /// Creates and opens the file that accumulates the bytes.
    ///
    /// - Throws: ``RuntimeProvisioningError/downloadFailed(_:)`` when the file cannot be
    ///   created or opened for writing.
    private func prepareFile() throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: partial.path) {
            try? fileManager.createDirectory(
                at: partial.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard fileManager.createFile(atPath: partial.path, contents: nil) else {
                throw RuntimeProvisioningError.downloadFailed("Runtime 下载文件无法创建")
            }
        }
        do {
            let handle = try FileHandle(forWritingTo: partial)
            try handle.seekToEnd()
            lock.lock()
            self.handle = handle
            lock.unlock()
        } catch {
            throw RuntimeProvisioningError.downloadFailed(error.localizedDescription)
        }
    }

    /// Resumes the waiting caller exactly once.
    ///
    /// - Parameter result: Response or failure to hand back.
    private func finish(_ result: Result<HTTPURLResponse, Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
