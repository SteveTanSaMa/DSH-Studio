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
