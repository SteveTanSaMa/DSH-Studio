//
//  RuntimeDataProfile.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/21.
//

import CryptoKit
import Foundation

/// App-owned description of one Harness data environment.
///
/// The data directory is deliberately stored as a path instead of being
/// inferred from the Runtime directory. This lets multiple Runtime versions
/// keep separate data environments while preserving the user's existing
/// `DSH_HOME` as a legacy profile.
public struct RuntimeDataProfile: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: String
    public let name: String
    public let homePath: String
    public let dataFormatID: String?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        id: String,
        name: String,
        homeURL: URL,
        dataFormatID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.homePath = homeURL.standardizedFileURL.path
        self.dataFormatID = dataFormatID
    }

    public var homeURL: URL {
        URL(fileURLWithPath: homePath, isDirectory: true)
    }

    public var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && RuntimeDataProfileStore.isSafeIdentifier(id)
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && homeURL.isFileURL
            && homeURL.path.hasPrefix("/")
            && (dataFormatID == nil || !dataFormatID!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func replacing(dataFormatID: String?) -> RuntimeDataProfile {
        RuntimeDataProfile(
            schemaVersion: schemaVersion,
            id: id,
            name: name,
            homeURL: homeURL,
            dataFormatID: dataFormatID
        )
    }
}

/// The durable pair that the app considers active after a successful Runtime
/// activation. It is intentionally separate from the Runtime installation
/// manifest and from Harness-owned files.
public struct RuntimeActiveState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let profileID: String
    public let runtimeVersion: String
    public let previousRuntimeVersion: String?
    public let previousProfileID: String?
    public let dataFormatID: String?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        profileID: String,
        runtimeVersion: String,
        previousRuntimeVersion: String? = nil,
        previousProfileID: String? = nil,
        dataFormatID: String?
    ) {
        self.schemaVersion = schemaVersion
        self.profileID = profileID
        self.runtimeVersion = runtimeVersion
        self.previousRuntimeVersion = previousRuntimeVersion
        self.previousProfileID = previousProfileID
        self.dataFormatID = dataFormatID
    }

    public var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && RuntimeDataProfileStore.isSafeIdentifier(profileID)
            && RuntimeLocator.isSafeRuntimeVersion(runtimeVersion)
            && (previousRuntimeVersion == nil || !previousRuntimeVersion!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (previousRuntimeVersion == nil || RuntimeLocator.isSafeRuntimeVersion(previousRuntimeVersion!))
            && (previousProfileID == nil || RuntimeDataProfileStore.isSafeIdentifier(previousProfileID!))
            && (dataFormatID == nil || !dataFormatID!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

public enum RuntimeDataProfileStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidProfile
    case invalidActiveState
    case profileNotFound(String)
    case dataFormatUnknown
    case dataFormatMismatch(profile: String, runtime: String)
    case dataMigrationRequired(profile: String, runtime: String)
    case persistenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProfile:
            return "Runtime 数据环境描述无效"
        case .invalidActiveState:
            return "Runtime active-state.json 无效"
        case .profileNotFound(let id):
            return "找不到 Runtime 数据环境：\(id)"
        case .dataFormatUnknown:
            return "无法确认数据环境与 Runtime 的格式关系"
        case .dataFormatMismatch(let profile, let runtime):
            return "数据环境格式 \(profile) 与 Runtime 格式 \(runtime) 不兼容"
        case .dataMigrationRequired(let profile, let runtime):
            return "数据环境格式 \(profile) 需要迁移到 Runtime 格式 \(runtime)"
        case .persistenceFailed(let detail):
            return "Runtime 数据环境状态保存失败：\(detail)"
        }
    }
}

/// Persists app-owned data profile metadata without moving or rewriting user
/// data. Actual migration remains an explicit future operation.
public final class RuntimeDataProfileStore: @unchecked Sendable {
    public let supportDirectory: URL
    public let profilesDirectory: URL
    public let activeStateURL: URL

    private let fileManager: FileManager

    public init(
        supportDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.supportDirectory = supportDirectory.standardizedFileURL
        self.profilesDirectory = self.supportDirectory.appendingPathComponent(
            "DataProfiles",
            isDirectory: true
        )
        self.activeStateURL = self.supportDirectory.appendingPathComponent(
            "active-state.json",
            isDirectory: false
        )
        self.fileManager = fileManager
    }

    /// Reads valid profile descriptors and ignores incomplete entries left by
    /// an interrupted write or an older schema.
    public func profiles() -> [RuntimeDataProfile] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: profilesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { directory in
            guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true else {
                return nil
            }
            return profile(id: directory.lastPathComponent)
        }
        .sorted { $0.id < $1.id }
    }

    public func profile(id: String) -> RuntimeDataProfile? {
        guard Self.isSafeIdentifier(id) else { return nil }
        let url = profileFileURL(id: id)
        guard let data = try? Data(contentsOf: url),
              let profile = try? JSONDecoder().decode(RuntimeDataProfile.self, from: data),
              profile.id == id,
              profile.isValid else {
            return nil
        }
        return profile
    }

    public func activeState() -> RuntimeActiveState? {
        guard let data = try? Data(contentsOf: activeStateURL),
              let state = try? JSONDecoder().decode(RuntimeActiveState.self, from: data),
              state.isValid else {
            return nil
        }
        return state
    }

    public func activeProfile() -> RuntimeDataProfile? {
        guard let state = activeState() else { return nil }
        return profile(id: state.profileID)
    }

    public func previousProfile() -> RuntimeDataProfile? {
        guard let profileID = activeState()?.previousProfileID else { return nil }
        return profile(id: profileID)
    }

    public func profile(forHomeURL homeURL: URL) -> RuntimeDataProfile? {
        let path = homeURL.standardizedFileURL.path
        return profiles().first { $0.homeURL.standardizedFileURL.path == path }
    }

    /// A missing directory, or a directory containing only Finder metadata,
    /// can safely receive a format declaration after the first healthy launch.
    public func isDataHomeEmpty(_ homeURL: URL) -> Bool {
        guard fileManager.fileExists(atPath: homeURL.path) else { return true }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: homeURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return false
        }
        return entries.allSatisfy { $0.lastPathComponent == ".DS_Store" }
    }

    /// Returns the format belonging to the selected profile. A profile-specific
    /// lookup avoids accidentally comparing an update against another profile
    /// that happens to be recorded as active in an older app session. The
    /// active-state copy is not a fallback: missing profile metadata must stay
    /// unknown instead of being treated as proof about the data on disk.
    public func dataFormatID(forProfileID profileID: String?) -> String? {
        if let profileID {
            return profile(id: profileID)?.dataFormatID
        }
        return activeProfile()?.dataFormatID
    }

    /// Registers the existing user-selected DSH_HOME without copying it. The
    /// stable id lets later launches find the same legacy profile.
    @discardableResult
    public func ensureLegacyProfile(
        homeURL: URL,
        dataFormatID: String? = nil
    ) throws -> RuntimeDataProfile {
        let normalizedHome = homeURL.standardizedFileURL
        if let existing = profile(forHomeURL: normalizedHome) {
            return existing
        }

        let profile = RuntimeDataProfile(
            id: "legacy-\(Self.stableIdentifier(for: normalizedHome.path))",
            name: "现有 DSH_HOME",
            homeURL: normalizedHome,
            dataFormatID: normalizedFormatID(dataFormatID)
        )
        try save(profile)
        return profile
    }

    /// Creates a new isolated data environment. No existing data is reused or
    /// migrated by this operation.
    @discardableResult
    public func createProfile(
        name: String,
        dataFormatID: String?
    ) throws -> RuntimeDataProfile {
        guard normalizedFormatID(dataFormatID) != nil else {
            throw RuntimeDataProfileStoreError.dataFormatUnknown
        }
        let id = "profile-\(UUID().uuidString.lowercased())"
        let homeURL = profilesDirectory
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("DSH_HOME", isDirectory: true)
        try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let profile = RuntimeDataProfile(
            id: id,
            name: name,
            homeURL: homeURL,
            dataFormatID: normalizedFormatID(dataFormatID)
        )
        do {
            try save(profile)
        } catch {
            try? fileManager.removeItem(at: homeURL.deletingLastPathComponent())
            throw error
        }
        return profile
    }

    /// Records a successful Runtime/profile activation. It never changes the
    /// contents of the profile's data directory.
    @discardableResult
    public func activate(
        profile: RuntimeDataProfile,
        runtimeManifest: RuntimeInstallationManifest,
        dataHomeWasEmptyAtLaunch: Bool? = nil
    ) throws -> RuntimeDataProfile {
        guard profile.isValid else { throw RuntimeDataProfileStoreError.invalidProfile }
        let resolvedFormat: String?
        if let profileFormatID = profile.dataFormatID {
            guard let runtimeFormat = runtimeManifest.dataFormat else {
                throw RuntimeDataProfileStoreError.dataFormatUnknown
            }
            guard let compatibleFormat = try resolvedDataFormatID(
                profileFormatID: profileFormatID,
                runtimeFormat: runtimeFormat
            ) else {
                throw RuntimeDataProfileStoreError.dataFormatUnknown
            }
            resolvedFormat = compatibleFormat
        } else if let runtimeFormat = runtimeManifest.dataFormat {
            // Harness may create its first files before health-check completion.
            // Prefer the pre-launch observation when the caller has one; direct
            // callers retain the conservative current-directory check.
            let wasEmpty = dataHomeWasEmptyAtLaunch ?? isDataHomeEmpty(profile.homeURL)
            guard wasEmpty else {
                throw RuntimeDataProfileStoreError.dataFormatUnknown
            }
            resolvedFormat = runtimeFormat.id
        } else {
            // Preserve the existing legacy Runtime/profile pair when neither
            // side has a machine-readable format declaration. A later Runtime
            // with a declared format still fails closed before reusing it.
            resolvedFormat = nil
        }
        let oldState = activeState()
        let oldProfile = self.profile(id: profile.id)
        let persistedProfile = profile.replacing(dataFormatID: resolvedFormat)
        try save(persistedProfile)
        let previousRuntimeVersion: String?
        let previousProfileID: String?
        if oldState?.runtimeVersion == runtimeManifest.runtimeVersion {
            previousRuntimeVersion = oldState?.previousRuntimeVersion
            previousProfileID = oldState?.previousProfileID
        } else {
            previousRuntimeVersion = oldState?.runtimeVersion
            previousProfileID = oldState?.profileID
        }
        let state = RuntimeActiveState(
            profileID: persistedProfile.id,
            runtimeVersion: runtimeManifest.runtimeVersion,
            previousRuntimeVersion: previousRuntimeVersion,
            previousProfileID: previousProfileID,
            dataFormatID: resolvedFormat
        )
        guard state.isValid else {
            restoreProfileMetadata(oldProfile)
            throw RuntimeDataProfileStoreError.invalidActiveState
        }
        do {
            try persist(state, to: activeStateURL)
        } catch {
            restoreProfileMetadata(oldProfile)
            throw error
        }
        return persistedProfile
    }

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

    private func profileFileURL(id: String) -> URL {
        profilesDirectory
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("profile.json", isDirectory: false)
    }

    private func restoreProfileMetadata(_ profile: RuntimeDataProfile?) {
        guard let profile else { return }
        try? save(profile)
    }

    private func normalizedFormatID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func resolvedDataFormatID(
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

    private func persist<T: Encodable>(_ value: T, to url: URL) throws {
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

    private static func stableIdentifier(for path: String) -> String {
        SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
            .description
    }
}
