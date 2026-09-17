//
//  RuntimeDataProfile.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/21.
//

import CryptoKit
import Foundation

/// An app-owned description of one Harness data environment.
///
/// The data directory is stored as a path instead of being inferred from the
/// Runtime directory, so several Runtime versions can keep separate data
/// environments while the user's existing `DSH_HOME` remains a legacy profile.
/// App-owned description of one Harness data environment.
///
/// The data directory is deliberately stored as a path instead of being
/// inferred from the Runtime directory. This lets multiple Runtime versions
/// keep separate data environments while preserving the user's existing
/// `DSH_HOME` as a legacy profile.
public struct RuntimeDataProfile: Codable, Equatable, Sendable {
    /// The profile schema this app writes; any other version fails ``isValid``.
    public static let currentSchemaVersion = 1

    /// Schema version recorded with the profile.
    public let schemaVersion: Int
    /// Stable identifier, also used as the profile's directory name.
    public let id: String
    /// User-facing profile name.
    public let name: String
    /// Absolute path of the data directory this profile owns.
    public let homePath: String
    /// Identifier of the data format stored in that directory, when declared.
    public let dataFormatID: String?

    /// Creates a profile for one data directory.
    ///
    /// - Parameters:
    ///   - schemaVersion: Schema to record; defaults to ``currentSchemaVersion``.
    ///   - id: Stable identifier, also used as the directory name.
    ///   - name: User-facing name.
    ///   - homeURL: Data directory; a non-standardized value is standardized here.
    ///   - dataFormatID: Data format stored in the directory, when known.
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

    /// The data directory as a file URL.
    public var homeURL: URL {
        URL(fileURLWithPath: homePath, isDirectory: true)
    }

    /// Whether the recorded values are safe to use.
    ///
    /// Requires the current schema, a safe identifier, a non-empty name, an
    /// absolute file URL, and a non-blank data-format identifier when one is set.
    public var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && RuntimeDataProfileStore.isSafeIdentifier(id)
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && homeURL.isFileURL
            && homeURL.path.hasPrefix("/")
            && (dataFormatID == nil || !dataFormatID!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Returns a copy that records a different data-format identifier.
    ///
    /// - Parameter dataFormatID: Identifier to record; `nil` clears it.
    /// - Returns: A profile with the same identity and directory.
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

/// The profile and Runtime pair the app treats as active.
///
/// The record is written only after a Runtime activation succeeds, and is kept
/// separate from both the Runtime installation manifest and Harness-owned files.
/// The durable pair that the app considers active after a successful Runtime
/// activation. It is intentionally separate from the Runtime installation
/// manifest and from Harness-owned files.
public struct RuntimeActiveState: Codable, Equatable, Sendable {
    /// The active-state schema this app writes; any other version fails ``isValid``.
    public static let currentSchemaVersion = 1

    /// Schema version recorded with the active state.
    public let schemaVersion: Int
    /// Identifier of the active data profile.
    public let profileID: String
    /// Runtime build that is currently activated.
    public let runtimeVersion: String
    /// Runtime build that was active before the last activation, when known.
    public let previousRuntimeVersion: String?
    /// Data profile that was active before the last activation, when known.
    public let previousProfileID: String?
    /// Data format of the active profile, when declared.
    public let dataFormatID: String?

    /// Creates an active-state record.
    ///
    /// - Parameters:
    ///   - schemaVersion: Schema to record; defaults to ``currentSchemaVersion``.
    ///   - profileID: Identifier of the active data profile.
    ///   - runtimeVersion: Runtime build being activated.
    ///   - previousRuntimeVersion: Previously active Runtime build, when known.
    ///   - previousProfileID: Previously active profile, when known.
    ///   - dataFormatID: Data format of the active profile, when declared.
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

    /// Whether every recorded identifier and version is safe to use.
    ///
    /// Also validates the previous pair when it is present, so a rollback cannot
    /// restore an unsafe profile or version.
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
