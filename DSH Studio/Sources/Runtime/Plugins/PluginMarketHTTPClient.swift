//
//  PluginMarketHTTPClient.swift
//  DSH Studio
//

import Foundation
import DeepSeekHarness

public struct PluginMarketHTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

public protocol PluginMarketHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> PluginMarketHTTPResponse
}

public struct URLSessionPluginMarketHTTPTransport: PluginMarketHTTPTransport, Sendable {
    public init() {}

    public func send(_ request: URLRequest) async throws -> PluginMarketHTTPResponse {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PluginMarketHTTPError.invalidResponse("不是 HTTP 响应")
            }
            return PluginMarketHTTPResponse(statusCode: http.statusCode, data: data)
        } catch let error as PluginMarketHTTPError {
            throw error
        } catch {
            throw PluginMarketHTTPError.transport(error.localizedDescription)
        }
    }
}

/// Client for the read-only/diagnostic routes exposed by dsh-market.
/// Mutating the market itself remains a native Runtime lifecycle operation.
public final class PluginMarketHTTPClient: @unchecked Sendable {
    private let transport: any PluginMarketHTTPTransport
    private let decoder: JSONDecoder

    public init(
        transport: any PluginMarketHTTPTransport = URLSessionPluginMarketHTTPTransport()
    ) {
        self.transport = transport
        self.decoder = JSONDecoder()
    }

    public func status(baseURL: URL) async throws -> PluginMarketHTTPStatus {
        try await getJSON(path: "dsh-market/status", baseURL: baseURL)
    }

    public func updates(baseURL: URL) async throws -> PluginMarketUpdatesResponse {
        try await getJSON(path: "dsh-market/updates", baseURL: baseURL)
    }

    public func check(baseURL: URL) async throws -> Data {
        try await getData(path: "dsh-market/check", baseURL: baseURL)
    }

    public func logs(baseURL: URL) async throws -> String {
        let data = try await getData(path: "dsh-market/logs", baseURL: baseURL)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func getJSON<T: Decodable>(path: String, baseURL: URL) async throws -> T {
        let data = try await getData(path: path, baseURL: baseURL)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw PluginMarketHTTPError.invalidResponse(error.localizedDescription)
        }
    }

    private func getData(path: String, baseURL: URL) async throws -> Data {
        guard HarnessURLPolicy.isAllowedLoopback(baseURL),
              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              HarnessURLPolicy.isAllowedLoopback(url),
              url.host == baseURL.host,
              url.port == baseURL.port else {
            throw PluginMarketHTTPError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let detail = String(data: response.data, encoding: .utf8)
                ?? ""
            throw PluginMarketHTTPError.status(response.statusCode, detail)
        }
        return response.data
    }
}
