//
//  HarnessAPIClient.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import Foundation

/// One HTTP response from the loopback Harness API.
public struct HarnessHTTPResponse: Sendable {
    /// HTTP status code returned by Harness.
    public let statusCode: Int
    /// Raw response body, bounded by the transport.
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

/// Sends encoded loopback RPC requests on behalf of ``HarnessAPIClient``.
///
/// The seam exists so tests can answer RPC calls without a live Harness process.
public protocol HarnessAPITransport {
    /// Sends one already-encoded loopback RPC request.
    func send(_ request: URLRequest) async throws -> HarnessHTTPResponse
}

/// The production transport, backed by `URLSession`.
public struct URLSessionHarnessAPITransport: HarnessAPITransport, Sendable {
    /// Creates the shared-session transport.
    public init() {}

    /// Sends a request through `URLSession`.
    ///
    /// - Parameter request: Already-encoded loopback request.
    /// - Returns: The response status and body.
    /// - Throws: ``HarnessAPIError/invalidResponse`` when the response is not HTTP,
    ///   or the underlying `URLSession` error.
    public func send(_ request: URLRequest) async throws -> HarnessHTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HarnessAPIError.invalidResponse
        }
        return HarnessHTTPResponse(statusCode: httpResponse.statusCode, data: data)
    }
}

/// Failures raised while talking to the loopback Harness RPC surface.
///
/// Associated values carry raw detail; the user-facing sentence is produced by
/// ``errorDescription``.
public enum HarnessAPIError: Error, Equatable, LocalizedError, Sendable {
    /// The configured base URL is not an allowed loopback URL.
    case invalidBaseURL
    /// The request failed before a response arrived; carries the transport detail.
    case transport(String)
    /// The response was not an HTTP response.
    case invalidResponse
    /// Harness answered with a non-success status and an optional body excerpt.
    case httpStatus(Int, String)
    /// The RPC envelope was missing, mismatched, or undecodable.
    case invalidEnvelope(String)
    /// Harness rejected the call; carries its own error code and message.
    case remote(code: String, message: String)

    /// A localized, user-facing description of the failure.
    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Harness Runtime 地址不可用"
        case .transport(let detail):
            return "无法连接 Harness Runtime：\(detail)"
        case .invalidResponse:
            return "Harness Runtime 返回了无效响应"
        case .httpStatus(let status, let detail):
            return detail.isEmpty ? "Harness API 请求失败（HTTP \(status)）" : "Harness API 请求失败（HTTP \(status)）：\(detail)"
        case .invalidEnvelope(let detail):
            return "Harness API 响应格式无效：\(detail)"
        case .remote(let code, let message):
            return "Harness 设置拒绝了请求（\(code)）：\(message)"
        }
    }
}

/// Native client for the official loopback Harness RPC surface.
public final class HarnessAPIClient {
    private let baseURL: URL
    private let transport: any HarnessAPITransport

    /// Creates a client for one Harness base URL.
    ///
    /// - Parameters:
    ///   - baseURL: Loopback URL reported by the Runtime; validated on every call.
    ///   - transport: Transport seam; defaults to `URLSession`.
    public init(
        baseURL: URL,
        transport: any HarnessAPITransport = URLSessionHarnessAPITransport()
    ) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// Reads every settings namespace from Harness.
    ///
    /// The official envelope is returned without flattening unknown fields.
    ///
    /// - Returns: The settings snapshot, including unknown fields.
    /// - Throws: ``HarnessAPIError`` when the base URL is not loopback, the request
    ///   fails, or Harness rejects it.
    public func settingsDescribe() async throws -> HarnessSettingsSnapshot {
        try await call(
            endpoint: "settings/describe",
            args: .object([:]),
            responseType: HarnessSettingsSnapshot.self
        )
    }

    /// Applies a shallow patch to one namespace.
    ///
    /// Harness's revision is preserved unless `expectedRevision` is supplied.
    ///
    /// - Parameters:
    ///   - namespace: Namespace to patch.
    ///   - patch: Top-level keys to merge into the namespace.
    ///   - expectedRevision: Revision the caller last saw, enabling conflict detection.
    /// - Returns: The updated namespace.
    /// - Throws: ``HarnessAPIError`` when the request fails or Harness reports a
    ///   revision conflict.
    public func settingsUpdate(
        namespace: String,
        patch: [String: HarnessJSONValue],
        expectedRevision: Int?
    ) async throws -> HarnessSettingNamespace {
        var args: [String: HarnessJSONValue] = [
            "ns": .string(namespace),
            "patch": .object(patch)
        ]
        if let expectedRevision {
            args["expectedRevision"] = .number(Double(expectedRevision))
        }
        return try await call(
            endpoint: "settings/update",
            args: .object(args),
            responseType: HarnessSettingNamespace.self
        )
    }

    /// Applies path operations to one namespace.
    ///
    /// Use this instead of ``settingsUpdate(namespace:patch:expectedRevision:)`` for
    /// nested writes and for removals.
    ///
    /// - Parameters:
    ///   - namespace: Namespace to mutate.
    ///   - operations: Ordered path operations to apply.
    ///   - expectedRevision: Revision the caller last saw, enabling conflict detection.
    /// - Returns: The updated namespace.
    /// - Throws: ``HarnessAPIError`` when the request fails or Harness reports a
    ///   revision conflict.
    public func settingsMutate(
        namespace: String,
        operations: [HarnessSettingOperation],
        expectedRevision: Int?
    ) async throws -> HarnessSettingNamespace {
        var args: [String: HarnessJSONValue] = [
            "ns": .string(namespace),
            "ops": .array(operations.map { operation in
                switch operation {
                case .set(let path, let value):
                    return .object([
                        "op": .string("set"),
                        "path": .array(path.map(HarnessJSONValue.string)),
                        "value": value
                    ])
                case .unset(let path):
                    return .object([
                        "op": .string("unset"),
                        "path": .array(path.map(HarnessJSONValue.string))
                    ])
                }
            })
        ]
        if let expectedRevision {
            args["expectedRevision"] = .number(Double(expectedRevision))
        }
        return try await call(
            endpoint: "settings/mutate",
            args: .object(args),
            responseType: HarnessSettingNamespace.self
        )
    }

    /// Calls one remote endpoint on the loopback RPC surface.
    ///
    /// The surface addresses a method as `<namespace>/<method>` on the `/api` channel and
    /// carries named arguments in a single `args` object, so both the path and the
    /// envelope are derived from `endpoint` rather than restated per caller.
    ///
    /// - Parameters:
    ///   - endpoint: Remote endpoint, for example `settings/describe`.
    ///   - args: Named arguments object for that endpoint.
    ///   - responseType: Expected success value.
    /// - Returns: The decoded success value.
    /// - Throws: ``HarnessAPIError`` when the URL, transport, envelope, or remote
    ///   result fails.
    private func call<Value: Decodable>(
        endpoint: String,
        args: HarnessJSONValue,
        responseType: Value.Type
    ) async throws -> Value {
        // Every public operation funnels through this check, so test doubles
        // cannot accidentally hide a remote base URL in production.
        guard HarnessURLPolicy.isAllowedLoopback(baseURL),
              endpoint.split(separator: "/").allSatisfy({ !$0.isEmpty }) else {
            throw HarnessAPIError.invalidBaseURL
        }

        var url = HarnessURLPolicy.baseURL(from: baseURL).appendingPathComponent("api", isDirectory: true)
        for segment in endpoint.split(separator: "/") {
            url.appendPathComponent(String(segment))
        }
        let rpcID = UUID().uuidString
        let body = RPCRequest(
            type: "client-request",
            rpcID: rpcID,
            method: endpoint,
            payload: RPCArgsPayload(args: args)
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw HarnessAPIError.invalidEnvelope("无法编码请求")
        }

        let response: HarnessHTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as HarnessAPIError {
            throw error
        } catch {
            throw HarnessAPIError.transport(error.localizedDescription)
        }
        guard (200...299).contains(response.statusCode) else {
            throw HarnessAPIError.httpStatus(response.statusCode, response.detailText)
        }

        let envelope: RPCResponse<Value>
        do {
            envelope = try JSONDecoder().decode(RPCResponse<Value>.self, from: response.data)
        } catch {
            throw HarnessAPIError.invalidEnvelope(error.localizedDescription)
        }
        guard envelope.rpcID == rpcID else {
            throw HarnessAPIError.invalidEnvelope("rpcId 不匹配")
        }
        if let type = envelope.type, type != "server-response" {
            throw HarnessAPIError.invalidEnvelope("响应类型 \(type)")
        }
        switch envelope.result {
        case .success(let value):
            return value
        case .failure(let error):
            throw HarnessAPIError.remote(code: error.code, message: error.message)
        }
    }
}

/// The named-argument payload every loopback RPC request carries.
///
/// The surface accepts exactly one plain-object `args` field, so the object is built
/// once per endpoint rather than restated in the envelope.
private struct RPCArgsPayload: Encodable {
    /// Named arguments of the remote method.
    let args: HarnessJSONValue
}

private struct RPCRequest<Payload: Encodable>: Encodable {
    let type: String
    let rpcID: String
    let method: String
    let payload: Payload

    enum CodingKeys: String, CodingKey {
        case type
        case rpcID = "rpcId"
        case method
        case payload
    }
}

private struct RPCResponse<Value: Decodable>: Decodable {
    let type: String?
    let rpcID: String
    let result: RPCResult<Value>

    enum CodingKeys: String, CodingKey {
        case type
        case rpcID = "rpcId"
        case result
    }
}

private enum RPCResult<Value: Decodable>: Decodable {
    case success(Value)
    case failure(RPCErrorPayload)

    enum CodingKeys: String, CodingKey {
        case ok
        case value
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(Bool.self, forKey: .ok) {
            self = .success(try container.decode(Value.self, forKey: .value))
        } else {
            self = .failure(try container.decode(RPCErrorPayload.self, forKey: .error))
        }
    }
}

private struct RPCErrorPayload: Decodable {
    let code: String
    let message: String
}

private extension HarnessHTTPResponse {
    var detailText: String {
        guard let text = String(data: data.prefix(512), encoding: .utf8) else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
