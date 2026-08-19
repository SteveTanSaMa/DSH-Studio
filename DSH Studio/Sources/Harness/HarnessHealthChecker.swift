//
//  HarnessHealthChecker.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import Foundation

/// Performs the minimal loopback RPC used to decide whether Harness is ready.
public protocol HarnessHealthChecking {
    /// Returns true only when the local host.describe endpoint replies with ok.
    func check(baseURL: URL, timeout: TimeInterval) async -> Bool
}

/// Production health checker backed by URLSession.
public final class SystemHarnessHealthChecker: HarnessHealthChecking {
    public init() {}

    public func check(baseURL: URL, timeout: TimeInterval) async -> Bool {
        // Validate before creating a request so a bad or remote URL never
        // reaches the transport layer.
        guard HarnessURLPolicy.isAllowedLoopback(baseURL) else { return false }
        let endpoint = baseURL.appendingPathComponent("api/host.describe")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            #"{"type":"client-request","rpcId":"native-health","method":"host.describe","payload":{}}"#.utf8
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return false
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let ok = result["ok"] as? Bool else {
                return false
            }
            return ok
        } catch {
            return false
        }
    }
}
