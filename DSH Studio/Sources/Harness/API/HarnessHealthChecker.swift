//
//  HarnessHealthChecker.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import Foundation

/// Performs the minimal loopback RPC used to decide whether Harness is ready.
public protocol HarnessHealthChecking {
    /// Returns true when a supported local Harness health endpoint replies with ok.
    func check(baseURL: URL, timeout: TimeInterval) async -> Bool
}

/// Production health checker backed by URLSession.
public final class SystemHarnessHealthChecker: HarnessHealthChecking {
    public init() {}

    public func check(baseURL: URL, timeout: TimeInterval) async -> Bool {
        // Validate before creating a request so a bad or remote URL never
        // reaches the transport layer.
        guard HarnessURLPolicy.isAllowedLoopback(baseURL) else { return false }
        do {
            let session = URLSession.shared
            let cleanBaseURL = HarnessURLPolicy.baseURL(from: baseURL)

            // New Harness versions exchange the printed process token for a
            // signed cookie before accepting Host API requests. Keeping this
            // on URLSession.shared also authenticates native WebSocket and
            // download clients that start after Runtime becomes ready.
            if hasProcessToken(in: baseURL) {
                var exchange = URLRequest(url: baseURL)
                exchange.httpMethod = "GET"
                exchange.timeoutInterval = timeout
                _ = try await session.data(for: exchange)
            }

            if try await call(
                method: "settings/describe",
                payload: .object(["args": .object([:])]),
                baseURL: cleanBaseURL,
                timeout: timeout,
                session: session
            ) {
                return true
            }

            // Keep older Runtime bundles launchable while the catalog moves
            // to the current slash-separated Remote endpoint contract.
            return try await call(
                method: "host.describe",
                payload: .object([:]),
                baseURL: cleanBaseURL,
                timeout: timeout,
                session: session
            )
        } catch {
            return false
        }
    }

    private func call(
        method: String,
        payload: HarnessJSONValue,
        baseURL: URL,
        timeout: TimeInterval,
        session: URLSession
    ) async throws -> Bool {
        let endpoint = baseURL.appendingPathComponent("api", isDirectory: true)
            .appendingPathComponent(method, isDirectory: false)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = HealthRPCRequest(
            type: "client-request",
            rpcID: "native-health",
            method: method,
            payload: payload
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return false
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let ok = result["ok"] as? Bool else {
            return false
        }
        return ok
    }

    private func hasProcessToken(in url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
            $0.name == "token" && !($0.value ?? "").isEmpty
        } == true
    }
}

private struct HealthRPCRequest: Encodable {
    let type: String
    let rpcID: String
    let method: String
    let payload: HarnessJSONValue

    enum CodingKeys: String, CodingKey {
        case type
        case rpcID = "rpcId"
        case method
        case payload
    }
}
