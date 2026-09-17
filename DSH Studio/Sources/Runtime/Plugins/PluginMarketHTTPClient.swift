//
//  PluginMarketHTTPClient.swift
//  DSH Studio
//

import Foundation
import DeepSeekHarness

/// One HTTP response from a dsh-market route.
public struct PluginMarketHTTPResponse: Sendable {
    /// HTTP status code returned by the market route.
    public let statusCode: Int
    /// Raw response body, decoded by the JSON and text helpers below.
    public let data: Data

    /// Creates a response value.
    ///
    /// - Parameters:
    ///   - statusCode: HTTP status code.
    ///   - data: Raw response body.
    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

/// Sends encoded requests to dsh-market routes on behalf of the client.
///
/// The seam exists so tests can answer market routes without a live Runtime.
public protocol PluginMarketHTTPTransport: Sendable {
    /// Sends one request and returns its status and body.
    func send(_ request: URLRequest) async throws -> PluginMarketHTTPResponse
}

/// The production transport, backed by `URLSession`.
public struct URLSessionPluginMarketHTTPTransport: PluginMarketHTTPTransport, Sendable {
    /// Creates the shared-session transport.
    public init() {}

    /// Sends a request through `URLSession`.
    ///
    /// - Parameter request: Already-validated loopback request.
    /// - Returns: The response status and body.
    /// - Throws: ``PluginMarketHTTPError`` when the response is not HTTP or the
    ///   request fails at the transport level.
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

/// Client for the read-only and diagnostic routes exposed by dsh-market.
///
/// Mutating the market itself stays a native Runtime lifecycle operation, so this
/// client only ever issues GET requests.
public final class PluginMarketHTTPClient: @unchecked Sendable {
    private let transport: any PluginMarketHTTPTransport
    private let decoder: JSONDecoder

    /// Creates a client.
    ///
    /// - Parameter transport: Transport seam; defaults to `URLSession`.
    public init(
        transport: any PluginMarketHTTPTransport = URLSessionPluginMarketHTTPTransport()
    ) {
        self.transport = transport
        self.decoder = JSONDecoder()
    }

    /// Reads the market's own status payload.
    ///
    /// - Parameter baseURL: Loopback URL of the running Harness server.
    /// - Returns: The decoded status payload.
    /// - Throws: ``PluginMarketHTTPError`` when the URL is rejected, the request
    ///   fails, or the payload does not decode.
    public func status(baseURL: URL) async throws -> PluginMarketHTTPStatus {
        try await getJSON(path: "dsh-market/status", baseURL: baseURL)
    }

    /// Reads the market's update feed.
    ///
    /// - Parameter baseURL: Loopback URL of the running Harness server.
    /// - Returns: The decoded update feed.
    /// - Throws: ``PluginMarketHTTPError`` when the URL is rejected, the request
    ///   fails, or the payload does not decode.
    public func updates(baseURL: URL) async throws -> PluginMarketUpdatesResponse {
        try await getJSON(path: "dsh-market/updates", baseURL: baseURL)
    }

    /// Runs the market's self-check route.
    ///
    /// - Parameter baseURL: Loopback URL of the running Harness server.
    /// - Returns: The raw check output, left undecoded because the route is diagnostic.
    /// - Throws: ``PluginMarketHTTPError`` when the URL is rejected or the request fails.
    public func check(baseURL: URL) async throws -> Data {
        try await getData(path: "dsh-market/check", baseURL: baseURL)
    }

    /// Reads the market's log output.
    ///
    /// - Parameter baseURL: Loopback URL of the running Harness server.
    /// - Returns: The log text, or an empty string when the body is not UTF-8.
    /// - Throws: ``PluginMarketHTTPError`` when the URL is rejected or the request fails.
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
