//
//  RuntimeCatalogTransport.swift
//  DSH Studio
//

import Foundation

/// Fetches the signed catalog bytes.
///
/// The seam exists so tests can answer the catalog without a network.
public protocol RuntimeCatalogFetching: Sendable {
    /// Downloads the catalog payload.
    ///
    /// - Parameter url: Trusted catalog URL.
    /// - Returns: The raw signed envelope bytes.
    /// - Throws: When the request fails or the response is not usable.
    func fetch(from url: URL) async throws -> Data
}

/// The production fetcher, backed by `URLSession`.
public struct URLSessionRuntimeCatalogFetcher: RuntimeCatalogFetching, Sendable {
    /// Creates a fetcher with no shared state.
    public init() {}

    /// Downloads the signed catalog after checking both endpoints.
    ///
    /// The requested URL must be the official catalog location, and the response must
    /// be a success that either stayed on that location or was redirected to GitHub's
    /// release-asset host, so a redirect cannot move the download somewhere else.
    ///
    /// - Parameter url: Trusted catalog URL.
    /// - Returns: The raw signed envelope bytes.
    /// - Throws: ``RuntimeCatalogError/downloadFailed(_:)`` when the URL is untrusted,
    ///   the request fails, or the status or redirect target is unexpected.
    public func fetch(from url: URL) async throws -> Data {
        guard RuntimeReleaseCatalog.isTrustedCatalogURL(url) else {
            throw RuntimeCatalogError.downloadFailed("catalog 地址不是受信任的官方地址")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RuntimeCatalogError.downloadFailed(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse,
              let finalURL = httpResponse.url,
              (200...299).contains(httpResponse.statusCode),
              (finalURL.host == "release-assets.githubusercontent.com"
                  || RuntimeReleaseCatalog.isTrustedCatalogURL(finalURL)) else {
            throw RuntimeCatalogError.downloadFailed("服务器返回了无效 HTTP 状态或重定向地址")
        }
        return data
    }
}
