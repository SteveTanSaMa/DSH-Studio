//
//  RuntimeDataProfileStore+Persistence.swift
//  DSH Studio
//

import CryptoKit
import Foundation

/// Persistence and format-compatibility helpers for data profiles.
///
/// Writes are atomic and validated: an invalid profile is rejected before any
/// file is created, so a broken descriptor cannot become readable later.
extension RuntimeDataProfileStore {
    /// Writes one profile descriptor.
    ///
    /// - Parameter profile: Profile to persist; it must satisfy ``RuntimeDataProfile/isValid``.
    /// - Throws: ``RuntimeDataProfileStoreError`` when the profile is invalid or the
    ///   file cannot be written.
    public func save(_ profile: RuntimeDataProfile) throws {
        guard profile.isValid else { throw RuntimeDataProfileStoreError.invalidProfile }
        let directory = profilesDirectory.appendingPathComponent(profile.id, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try persist(profile, to: profileFileURL(id: profile.id))
        } catch let error as RuntimeDataProfileStoreError {
            throw error
        } catch {
            throw RuntimeDataProfileStoreError.persistenceFailed(error.localizedDescription)
        }
    }

    /// Whether an identifier may be used as a profile directory name.
    ///
    /// - Parameter value: Candidate identifier.
    /// - Returns: `true` for a non-empty name of ASCII letters, digits, `-`, `_`, and
    ///   `.` that is not `.` or `..`.
    public static func isSafeIdentifier(_ value: String) -> Bool {
        value != "." && value != ".."
            && !value.isEmpty && value.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
            }
    }

    /// Path of the descriptor file for one profile identifier.
    ///
    /// - Parameter id: Profile identifier.
    /// - Returns: `DataProfiles/<id>/profile.json`.
    func profileFileURL(id: String) -> URL {
        profilesDirectory
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("profile.json", isDirectory: false)
    }

    /// Re-saves a descriptor that was read before a failed operation.
    ///
    /// - Parameter profile: Descriptor to restore; `nil` is ignored.
    func restoreProfileMetadata(_ profile: RuntimeDataProfile?) {
        guard let profile else { return }
        try? save(profile)
    }

    /// Trims a format identifier, treating blank input as absent.
    ///
    /// - Parameter value: Raw identifier.
    /// - Returns: The trimmed identifier, or `nil` when it is empty or absent.
    func normalizedFormatID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Resolves the data format an activation should record.
    ///
    /// A profile without a recorded format adopts the Runtime's, and a Runtime
    /// without a declaration for an already-recorded format fails closed.
    ///
    /// - Parameters:
    ///   - profileFormatID: Format the profile already records, if any.
    ///   - runtimeFormat: Format the Runtime declares, if any.
    /// - Returns: The format identifier the profile should keep.
    /// - Throws: ``RuntimeDataProfileStoreError`` when the formats are incompatible,
    ///   require migration, or cannot be determined.
    func resolvedDataFormatID(
        profileFormatID: String?,
        runtimeFormat: RuntimeDataFormatDescriptor?
    ) throws -> String? {
        guard let profileFormatID else {
            return runtimeFormat?.id
        }
        guard let runtimeFormat else {
            throw RuntimeDataProfileStoreError.dataFormatUnknown
        }
        switch runtimeFormat.compatibility(with: profileFormatID) {
        case .compatible:
            return profileFormatID
        case .incompatible:
            throw RuntimeDataProfileStoreError.dataFormatMismatch(
                profile: profileFormatID,
                runtime: runtimeFormat.id
            )
        case .requiresMigration:
            throw RuntimeDataProfileStoreError.dataMigrationRequired(
                profile: profileFormatID,
                runtime: runtimeFormat.id
            )
        case .unknown:
            throw RuntimeDataProfileStoreError.dataFormatUnknown
        }
    }

    /// Encodes a value as pretty-printed JSON and writes it atomically.
    ///
    /// - Parameters:
    ///   - value: Value to encode.
    ///   - url: Destination file; parent directories are created as needed.
    /// - Throws: ``RuntimeDataProfileStoreError/persistenceFailed(_:)`` on any write
    ///   or encoding failure.
    func persist<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            throw RuntimeDataProfileStoreError.persistenceFailed(error.localizedDescription)
        }
    }

    /// Derives a stable, path-safe identifier from a filesystem path.
    ///
    /// - Parameter path: Path to derive from.
    /// - Returns: The first 16 hex characters of the path's SHA-256 digest.
    static func stableIdentifier(for path: String) -> String {
        SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
            .description
    }
}
