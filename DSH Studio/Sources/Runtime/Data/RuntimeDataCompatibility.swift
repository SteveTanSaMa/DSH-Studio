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
    /// Identifier of the data format this release writes.
    public let id: String
    /// Format identifiers the release can read without migration.
    public let compatibleWith: [String]
    /// Migration identifier to run for an older stored format.
    ///
    /// Used when the stored format is neither this one nor listed in
    /// ``compatibleWith``; `nil` means no migration is offered.
    public let migration: String?

    /// Creates a data-format declaration.
    ///
    /// - Parameters:
    ///   - id: Identifier of the format this release writes.
    ///   - compatibleWith: Formats readable without migration.
    ///   - migration: Migration identifier offered for older formats.
    public init(
        id: String,
        compatibleWith: [String] = [],
        migration: String? = nil
    ) {
        self.id = id
        self.compatibleWith = compatibleWith
        self.migration = migration
    }

    /// Decodes a declaration, treating a missing compatibility list as empty.
    ///
    /// - Parameter decoder: Decoder positioned at the declaration object.
    /// - Throws: A `DecodingError` when `id` is missing.
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

    /// Whether the declaration names a format and lists only named formats.
    public var isValid: Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !compatibleWith.contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    /// Compares this declaration with the format a data home already stores.
    ///
    /// - Parameter currentFormatID: Format stored in the data home, or `nil` when the
    ///   profile is not registered.
    /// - Returns: ``RuntimeDataCompatibility/unknown`` without a stored format,
    ///   otherwise compatibility, incompatibility, or the need for migration.
    public func compatibility(with currentFormatID: String?) -> RuntimeDataCompatibility {
        guard let currentFormatID else { return .unknown }
        if currentFormatID == id || compatibleWith.contains(currentFormatID) {
            return .compatible
        }
        return migration == nil ? .incompatible : .requiresMigration
    }
}

/// Whether a release can reuse the data a profile already holds.
public enum RuntimeDataCompatibility: String, Codable, Equatable, Sendable {
    /// The stored format is unknown, so callers must fail closed.
    case unknown
    /// The release reads the stored format as-is.
    case compatible
    /// The stored format cannot be read and no migration is offered.
    case incompatible
    /// The stored format can be migrated before the release runs.
    case requiresMigration
}
