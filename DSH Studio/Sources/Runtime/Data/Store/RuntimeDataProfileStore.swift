//
//  RuntimeDataProfileStore.swift
//  DSH Studio
//

import Foundation

/// Persists app-owned data profile metadata.
///
/// User data is never moved or rewritten; an actual migration remains an explicit
/// future operation.
public final class RuntimeDataProfileStore: @unchecked Sendable {
    /// The standardized app support directory holding profile metadata.
    public let supportDirectory: URL
    /// `DataProfiles`, where one JSON file per profile is stored.
    public let profilesDirectory: URL
    /// `active-state.json`, the durable activation record.
    public let activeStateURL: URL

    /// File system seam, shared with this store's activation and persistence extensions.
    let fileManager: FileManager

    /// Creates a store rooted at an app support directory.
    ///
    /// - Parameters:
    ///   - supportDirectory: App support directory; a non-standardized value is
    ///     standardized here.
    ///   - fileManager: File system seam used by tests.
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

    /// Reads every valid profile descriptor.
    ///
    /// Incomplete entries left by an interrupted write or an older schema are
    /// ignored rather than reported.
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

    /// Reads one profile descriptor.
    ///
    /// - Parameter id: Profile identifier; unsafe identifiers return `nil`.
    /// - Returns: The profile when the file exists, decodes, and is valid.
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

    /// Reads the durable activation record.
    ///
    /// - Returns: The record, or `nil` when it is missing or invalid.
    public func activeState() -> RuntimeActiveState? {
        guard let data = try? Data(contentsOf: activeStateURL),
              let state = try? JSONDecoder().decode(RuntimeActiveState.self, from: data),
              state.isValid else {
            return nil
        }
        return state
    }

    /// The profile named by the activation record.
    ///
    /// - Returns: The active profile, or `nil` when the record or profile is unusable.
    public func activeProfile() -> RuntimeDataProfile? {
        guard let state = activeState() else { return nil }
        return profile(id: state.profileID)
    }

    /// The profile that was active before the last activation.
    ///
    /// - Returns: The previous profile, or `nil` when none is recorded or readable.
    public func previousProfile() -> RuntimeDataProfile? {
        guard let profileID = activeState()?.previousProfileID else { return nil }
        return profile(id: profileID)
    }

    /// Finds the profile that owns a data directory.
    ///
    /// - Parameter homeURL: Data directory to match; comparison is on standardized paths.
    /// - Returns: The first matching profile, or `nil` when none matches.
    public func profile(forHomeURL homeURL: URL) -> RuntimeDataProfile? {
        let path = homeURL.standardizedFileURL.path
        return profiles().first { $0.homeURL.standardizedFileURL.path == path }
    }

    /// Whether a data directory can safely receive a format declaration.
    ///
    /// A missing directory, or one containing only Finder metadata, counts as
    /// empty.
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

    /// Returns the format belonging to the selected profile.
    ///
    /// A profile-specific lookup avoids accidentally comparing an update against
    /// another profile that happens to be recorded as active in an older app
    /// session. The
    /// active-state copy is not a fallback: missing profile metadata must stay
    /// unknown instead of being treated as proof about the data on disk.
    public func dataFormatID(forProfileID profileID: String?) -> String? {
        if let profileID {
            return profile(id: profileID)?.dataFormatID
        }
        return activeProfile()?.dataFormatID
    }
}
