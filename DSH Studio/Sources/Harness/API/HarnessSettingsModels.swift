//
//  HarnessSettingsModels.swift
//  DSH Studio
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
