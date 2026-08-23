//
//  RuntimeDataCompatibility.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/21.
//

import Foundation

/// Machine-readable data contract supplied by a Harness Runtime release.
///
/// The app must not infer compatibility from semantic version numbers. When a
/// release does not provide this declaration, the result is intentionally
/// unknown and callers must fail closed before reusing an existing data home.
public struct RuntimeDataFormatDescriptor: Codable, Equatable, Sendable {
    public let id: String
    public let compatibleWith: [String]
    public let migration: String?

    public init(
        id: String,
        compatibleWith: [String] = [],
        migration: String? = nil
    ) {
        self.id = id
        self.compatibleWith = compatibleWith
        self.migration = migration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        compatibleWith = try container.decodeIfPresent([String].self, forKey: .compatibleWith) ?? []
        migration = try container.decodeIfPresent(String.self, forKey: .migration)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case compatibleWith
        case migration
    }

    public var isValid: Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !compatibleWith.contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    public func compatibility(with currentFormatID: String?) -> RuntimeDataCompatibility {
        guard let currentFormatID else { return .unknown }
        if currentFormatID == id || compatibleWith.contains(currentFormatID) {
            return .compatible
        }
        return migration == nil ? .incompatible : .requiresMigration
    }
}

public enum RuntimeDataCompatibility: String, Codable, Equatable, Sendable {
    case unknown
    case compatible
    case incompatible
    case requiresMigration
}
