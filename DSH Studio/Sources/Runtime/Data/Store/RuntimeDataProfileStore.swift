//
//  RuntimeDataProfileStore.swift
//  DSH Studio
//

import Foundation

/// Persists app-owned data profile metadata without moving or rewriting user
/// data. Actual migration remains an explicit future operation.
public final class RuntimeDataProfileStore: @unchecked Sendable {
    public let supportDirectory: URL
    public let profilesDirectory: URL
    public let activeStateURL: URL

    let fileManager: FileManager

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
}
