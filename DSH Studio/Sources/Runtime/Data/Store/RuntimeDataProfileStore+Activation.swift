//
//  RuntimeDataProfileStore+Activation.swift
//  DSH Studio
//

import Foundation

extension RuntimeDataProfileStore {
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
}
