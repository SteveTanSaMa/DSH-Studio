//
//  HarnessAPIClient.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import Foundation

/// JSON values returned by the Harness settings API. Keeping the value tree
/// typed lets the native settings editor preserve booleans, numbers, arrays,
/// and nested objects without maintaining a second settings schema.
public enum HarnessJSONValue: Codable, Equatable, Sendable {
    case object([String: HarnessJSONValue])
    case array([HarnessJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let object = try? container.decode([String: HarnessJSONValue].self) {
            self = .object(object)
            return
        }
        if let array = try? container.decode([HarnessJSONValue].self) {
            self = .array(array)
            return
        }
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }
        if let number = try? container.decode(Double.self) {
            self = .number(number)
            return
        }
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported Harness JSON value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let object):
            try container.encode(object)
        case .array(let array):
            try container.encode(array)
        case .string(let string):
            try container.encode(string)
        case .number(let number):
            try container.encode(number)
        case .bool(let bool):
            try container.encode(bool)
        case .null:
            try container.encodeNil()
        }
    }

    public var objectValue: [String: HarnessJSONValue]? {
        guard case .object(let object) = self else { return nil }
        return object
    }

    public var prettyPrintedData: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(self)
    }
}

public struct HarnessSettingSecret: Codable, Equatable, Sendable {
    public let path: [String]
    public let isSet: Bool

    enum CodingKeys: String, CodingKey {
        case path
        case isSet = "set"
    }
}

public struct HarnessSettingNamespace: Codable, Equatable, Identifiable, Sendable {
    public let ns: String
    public let schema: HarnessJSONValue
    public let value: HarnessJSONValue
    public let base: HarnessJSONValue?
    public let user: HarnessJSONValue?
    public let applies: String
    public let secrets: [HarnessSettingSecret]
    public let revision: Int

    public var id: String { ns }

    public init(
        ns: String,
        schema: HarnessJSONValue,
        value: HarnessJSONValue,
        base: HarnessJSONValue? = nil,
        user: HarnessJSONValue? = nil,
        applies: String,
        secrets: [HarnessSettingSecret],
        revision: Int
    ) {
        self.ns = ns
        self.schema = schema
        self.value = value
        self.base = base
        self.user = user
        self.applies = applies
        self.secrets = secrets
        self.revision = revision
    }
}

public struct HarnessSettingsSnapshot: Codable, Equatable, Sendable {
    public let writable: Bool
    public let hasDocument: Bool
    public let namespaces: [HarnessSettingNamespace]

    public init(writable: Bool, hasDocument: Bool, namespaces: [HarnessSettingNamespace]) {
        self.writable = writable
        self.hasDocument = hasDocument
        self.namespaces = namespaces
    }
}

public enum HarnessSettingOperation: Codable, Equatable, Sendable {
    case set(path: [String], value: HarnessJSONValue)
    case unset(path: [String])

    private enum CodingKeys: String, CodingKey {
        case op
        case path
        case value
    }

    private enum Operation: String, Codable {
        case set
        case unset
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .set(let path, let value):
            try container.encode(Operation.set, forKey: .op)
            try container.encode(path, forKey: .path)
            try container.encode(value, forKey: .value)
        case .unset(let path):
            try container.encode(Operation.unset, forKey: .op)
            try container.encode(path, forKey: .path)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let operation = try container.decode(Operation.self, forKey: .op)
        let path = try container.decode([String].self, forKey: .path)
        switch operation {
        case .set:
            self = .set(path: path, value: try container.decode(HarnessJSONValue.self, forKey: .value))
        case .unset:
            self = .unset(path: path)
        }
    }
}

public struct HarnessHTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

public protocol HarnessAPITransport {
    /// Sends one already-encoded loopback RPC request.
    func send(_ request: URLRequest) async throws -> HarnessHTTPResponse
}

public struct URLSessionHarnessAPITransport: HarnessAPITransport, Sendable {
    public init() {}

    public func send(_ request: URLRequest) async throws -> HarnessHTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HarnessAPIError.invalidResponse
        }
        return HarnessHTTPResponse(statusCode: httpResponse.statusCode, data: data)
    }
}

public enum HarnessAPIError: Error, Equatable, LocalizedError, Sendable {
    case invalidBaseURL
    case transport(String)
    case invalidResponse
    case httpStatus(Int, String)
    case invalidEnvelope(String)
    case remote(code: String, message: String)

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

    public init(
        baseURL: URL,
        transport: any HarnessAPITransport = URLSessionHarnessAPITransport()
    ) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// Reads the official settings envelope without flattening unknown fields.
    public func settingsDescribe() async throws -> HarnessSettingsSnapshot {
        try await call(
            method: "settings.describe",
            payload: .object([:]),
            responseType: HarnessSettingsSnapshot.self
        )
    }

    /// Applies a shallow settings patch while preserving Harness's revision.
    public func settingsUpdate(
        namespace: String,
        patch: [String: HarnessJSONValue],
        expectedRevision: Int?
    ) async throws -> HarnessSettingNamespace {
        var payload: [String: HarnessJSONValue] = [
            "ns": .string(namespace),
            "patch": .object(patch)
        ]
        if let expectedRevision {
            payload["expectedRevision"] = .number(Double(expectedRevision))
        }
        return try await call(
            method: "settings.update",
            payload: .object(payload),
            responseType: HarnessSettingNamespace.self
        )
    }

    /// Applies path operations for settings that need nested updates or unsets.
    public func settingsMutate(
        namespace: String,
        operations: [HarnessSettingOperation],
        expectedRevision: Int?
    ) async throws -> HarnessSettingNamespace {
        var payload: [String: HarnessJSONValue] = [
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
            payload["expectedRevision"] = .number(Double(expectedRevision))
        }
        return try await call(
            method: "settings.mutate",
            payload: .object(payload),
            responseType: HarnessSettingNamespace.self
        )
    }

    private func call<Value: Decodable>(
        method: String,
        payload: HarnessJSONValue,
        responseType: Value.Type
    ) async throws -> Value {
        // Every public operation funnels through this check, so test doubles
        // cannot accidentally hide a remote base URL in production.
        guard HarnessURLPolicy.isAllowedLoopback(baseURL) else {
            throw HarnessAPIError.invalidBaseURL
        }

        let endpoint = baseURL.appendingPathComponent("api", isDirectory: true)
            .appendingPathComponent(method, isDirectory: false)
        let rpcID = UUID().uuidString
        let body = RPCRequest(
            type: "client-request",
            rpcID: rpcID,
            method: method,
            payload: payload
        )
        var request = URLRequest(url: endpoint)
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
