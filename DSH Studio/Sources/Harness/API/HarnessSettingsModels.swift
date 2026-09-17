//
//  HarnessSettingsModels.swift
//  DSH Studio
//

import Foundation

/// A JSON value returned by the Harness settings API.
///
/// Keeping the value tree typed lets the native settings editor preserve
/// booleans, numbers, arrays, and nested objects without maintaining a second
/// settings schema.
/// JSON values returned by the Harness settings API. Keeping the value tree
/// typed lets the native settings editor preserve booleans, numbers, arrays,
/// and nested objects without maintaining a second settings schema.
public enum HarnessJSONValue: Codable, Equatable, Sendable {
    /// A JSON object whose values are themselves ``HarnessJSONValue`` instances.
    case object([String: HarnessJSONValue])
    /// A JSON array.
    case array([HarnessJSONValue])
    /// A JSON string.
    case string(String)
    /// A JSON number; integers and fractions share one representation.
    case number(Double)
    /// A JSON boolean.
    case bool(Bool)
    /// JSON `null`, used for an explicitly cleared value.
    case null

    /// Decodes the first JSON type the payload can represent.
    ///
    /// The probes run from the most to the least specific type, so an object or
    /// array is never flattened into a scalar.
    ///
    /// - Parameter decoder: Decoder positioned at the value.
    /// - Throws: A `DecodingError` when the payload is not a supported JSON value.
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

    /// Encodes the value through a single-value container.
    ///
    /// - Parameter encoder: Encoder that receives the value.
    /// - Throws: Rethrows whatever the underlying container encoding throws.
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

    /// The wrapped object when this value is an object, otherwise `nil`.
    public var objectValue: [String: HarnessJSONValue]? {
        guard case .object(let object) = self else { return nil }
        return object
    }

    /// A pretty-printed, key-sorted JSON rendering for diagnostics and logs.
    public var prettyPrintedData: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(self)
    }
}

/// One secret path reported for a settings namespace.
///
/// Only the path and whether a value is present are exposed: the secret itself
/// never leaves Harness.
public struct HarnessSettingSecret: Codable, Equatable, Sendable {
    /// Path of the secret inside the namespace's value tree.
    public let path: [String]
    /// Whether Harness has a value stored for this path.
    public let isSet: Bool

    /// Maps the API's secret payload onto ``HarnessSettingSecret`` fields.
    enum CodingKeys: String, CodingKey {
        /// Path of the secret inside the namespace's value tree.
        case path
        /// Whether Harness has a value stored; the API calls this field `set`.
        case isSet = "set"
    }
}

/// One settings namespace as returned by the Harness settings API.
public struct HarnessSettingNamespace: Codable, Equatable, Identifiable, Sendable {
    /// The namespace identifier, for example `agent` or `web`.
    public let ns: String
    /// The JSON schema Harness publishes for the namespace.
    public let schema: HarnessJSONValue
    /// The effective value Harness resolves for the namespace.
    public let value: HarnessJSONValue
    /// The value contributed by Harness itself, when supplied.
    public let base: HarnessJSONValue?
    /// The value contributed by the user's settings document, when supplied.
    public let user: HarnessJSONValue?
    /// Harness's applicability label for the namespace, passed through unchanged.
    public let applies: String
    /// Secret paths Harness reports for the namespace.
    public let secrets: [HarnessSettingSecret]
    /// Revision of the namespace, echoed back as `expectedRevision` when writing.
    public let revision: Int

    /// Identity for list rendering: the namespace string itself.
    public var id: String { ns }

    /// Creates a namespace value.
    ///
    /// - Parameters:
    ///   - ns: Namespace identifier.
    ///   - schema: JSON schema published by Harness.
    ///   - value: Effective value for the namespace.
    ///   - base: Value contributed by Harness, when supplied.
    ///   - user: Value contributed by the user document, when supplied.
    ///   - applies: Harness's applicability label, stored verbatim.
    ///   - secrets: Secret paths reported for the namespace.
    ///   - revision: Revision to echo back on the next write.
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

/// A complete read of the Harness settings document.
public struct HarnessSettingsSnapshot: Codable, Equatable, Sendable {
    /// Whether Harness accepts writes for this document.
    public let writable: Bool
    /// Whether a settings document exists yet.
    public let hasDocument: Bool
    /// Namespaces in the order Harness returned them.
    public let namespaces: [HarnessSettingNamespace]

    /// Creates a snapshot from a `settings.describe` response.
    ///
    /// - Parameters:
    ///   - writable: Whether Harness accepts writes.
    ///   - hasDocument: Whether a settings document exists.
    ///   - namespaces: Namespaces returned by Harness.
    public init(writable: Bool, hasDocument: Bool, namespaces: [HarnessSettingNamespace]) {
        self.writable = writable
        self.hasDocument = hasDocument
        self.namespaces = namespaces
    }
}

/// One edit applied to the Harness settings document.
///
/// The value encodes as `{"op": "set"|"unset", "path": [...], "value": ...}`,
/// which is the shape the settings API accepts for nested writes and removals.
public enum HarnessSettingOperation: Codable, Equatable, Sendable {
    /// Writes `value` at `path`, creating intermediate containers as needed.
    case set(path: [String], value: HarnessJSONValue)
    /// Removes the value at `path`.
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

    /// Encodes the operation in the API's `op` / `path` / `value` shape.
    ///
    /// - Parameter encoder: Encoder that receives the operation.
    /// - Throws: Rethrows whatever the keyed container encoding throws.
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

    /// Decodes an operation from the API's `op` / `path` / `value` shape.
    ///
    /// - Parameter decoder: Decoder positioned at the operation object.
    /// - Throws: A `DecodingError` when `op` is missing, unknown, or `value` is
    ///   absent for a `set` operation.
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
