//
//  HarnessHealthChecker.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import Foundation

/// Performs the minimal loopback RPC used to decide whether Harness is ready.
public protocol HarnessHealthChecking: Sendable {
    /// Returns true when a supported local Harness health endpoint replies with ok.
    func check(baseURL: URL, timeout: TimeInterval) async -> Bool
    /// Why the most recent probe reported an unhealthy Harness, for the log.
    ///
    /// A readiness failure used to be indistinguishable from a wrong reply, an
    /// unauthenticated one, or a server that was still starting; this carries the
    /// difference into the app log.
    var lastFailureDescription: String? { get }
}

/// Shared defaults for health checkers.
public extension HarnessHealthChecking {
    /// Reports nothing, for checkers that do not explain themselves.
    var lastFailureDescription: String? { nil }
}

/// Production health checker backed by URLSession.
public final class SystemHarnessHealthChecker: HarnessHealthChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var failure: String?

    /// Creates a checker with no shared state.
    public init() {}

    /// Why the most recent probe failed, when it did.
    public var lastFailureDescription: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    /// Probes Harness until one health route answers `ok`.
    ///
    /// The URL is validated before any request is built, and a printed process token
    /// is exchanged for a signed cookie on the shared session so later WebSocket and
    /// download clients are authenticated too. The current slash-separated route is
    /// tried first, then the `host.describe` spelling for older Runtime bundles.
    ///
    /// - Parameters:
    ///   - baseURL: Loopback URL reported by the Runtime.
    ///   - timeout: Seconds allowed per request.
    /// - Returns: `true` when Harness reports itself healthy.
    public func check(baseURL: URL, timeout: TimeInterval) async -> Bool {
        // Validate before creating a request so a bad or remote URL never
        // reaches the transport layer.
        guard HarnessURLPolicy.isAllowedLoopback(baseURL) else {
            record("非 loopback 地址")
            return false
        }
        do {
            let session = URLSession.shared
            let cleanBaseURL = HarnessURLPolicy.baseURL(from: baseURL)

            // New Harness versions exchange the printed process token for a
            // signed cookie before accepting Host API requests. Keeping this
            // on URLSession.shared also authenticates native WebSocket and
            // download clients that start after Runtime becomes ready.
            if hasProcessToken(in: baseURL) {
                // Every launch sets its own `dsh-auth-*` cookie on the loopback server,
                // and the shared cookie storage keeps them forever: once enough runs have
                // piled up, the exchange itself is rejected with HTTP 431 because the
                // request headers grew past what the server accepts. Only the cookie this
                // launch is about to receive is useful, so the stale ones go first.
                discardStaleHarnessCookies()
                var exchange = URLRequest(url: baseURL)
                exchange.httpMethod = "GET"
                exchange.timeoutInterval = timeout
                let (_, response) = try await session.data(for: exchange)
                guard let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) else {
                    record("token 换取失败：HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                    return false
                }
                let cookies = HTTPCookieStorage.shared.cookies(for: cleanBaseURL) ?? []
                guard !cookies.isEmpty else {
                    record("token 换取未返回会话 Cookie")
                    return false
                }
            }

            if try await call(
                method: "settings/describe",
                payload: .object(["args": .object([:])]),
                baseURL: cleanBaseURL,
                timeout: timeout,
                session: session
            ) {
                record(nil)
                return true
            }

            // Keep older Runtime bundles launchable while the catalog moves
            // to the current slash-separated Remote endpoint contract.
            let legacy = try await call(
                method: "host.describe",
                payload: .object([:]),
                baseURL: cleanBaseURL,
                timeout: timeout,
                session: session
            )
            record(legacy ? nil : "settings/describe 与 host.describe 都未返回 ok")
            return legacy
        } catch {
            record("请求失败：\(error.localizedDescription)")
            return false
        }
    }

    /// Stores the reason the next failed probe will report.
    ///
    /// - Parameter description: Reason, or `nil` to clear it after a healthy answer.
    private func record(_ description: String?) {
        lock.lock()
        failure = description
        lock.unlock()
    }

    /// Removes the Harness session cookies left behind by earlier launches.
    ///
    /// The loopback server names each cookie after the token it was issued for, so a
    /// stale one can never authenticate a later run; keeping them only grows the request
    /// headers until the server answers 431.
    private func discardStaleHarnessCookies() {
        let storage = HTTPCookieStorage.shared
        for cookie in storage.cookies ?? [] where cookie.name.hasPrefix("dsh-auth-") {
            storage.deleteCookie(cookie)
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
