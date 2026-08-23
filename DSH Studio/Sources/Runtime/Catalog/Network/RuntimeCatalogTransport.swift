//
//  RuntimeCatalogTransport.swift
//  DSH Studio
//

import Foundation

public protocol RuntimeCatalogFetching: Sendable {
    func fetch(from url: URL) async throws -> Data
}

public struct URLSessionRuntimeCatalogFetcher: RuntimeCatalogFetching, Sendable {
    public init() {}

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
