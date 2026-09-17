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
        // URLSession may follow redirects, so validate both the requested and
        // final response host before moving an archive into staging.
        guard isAllowedSourceURL(url) else {
            throw RuntimeProvisioningError.downloadFailed("Runtime 下载地址不是受信任的官方地址")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 900
        let (temporaryURL, response): (URL, URLResponse)
        do {
            (temporaryURL, response) = try await URLSession.shared.download(for: request)
        } catch {
            throw RuntimeProvisioningError.downloadFailed(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse,
              let finalURL = httpResponse.url,
              isAllowedFinalURL(finalURL),
              (200...299).contains(httpResponse.statusCode) else {
            throw RuntimeProvisioningError.downloadFailed("服务器返回了无效 HTTP 状态")
        }
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            throw RuntimeProvisioningError.downloadFailed(error.localizedDescription)
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
