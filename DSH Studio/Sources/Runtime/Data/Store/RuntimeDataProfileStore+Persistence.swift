//
//  RuntimeDataProfileStore+Persistence.swift
//  DSH Studio
//

import CryptoKit
import Foundation

extension RuntimeDataProfileStore {
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

    public static func isSafeIdentifier(_ value: String) -> Bool {
        value != "." && value != ".."
            && !value.isEmpty && value.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
            }
    }

    func profileFileURL(id: String) -> URL {
        profilesDirectory
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("profile.json", isDirectory: false)
    }

    func restoreProfileMetadata(_ profile: RuntimeDataProfile?) {
        guard let profile else { return }
        try? save(profile)
    }

    func normalizedFormatID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

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

    static func stableIdentifier(for path: String) -> String {
        SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
            .description
    }
}
