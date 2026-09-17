//
//  HarnessProfileStore.swift
//  DSH Studio
//

import CryptoKit
import Foundation

/// Manages Harness composition profiles separately from Runtime data homes.
///
/// Only profile manifests and selection state are owned here; user data stays in
/// the existing `DSH_HOME` and Runtime data-profile stores.
public final class HarnessProfileStore: @unchecked Sendable {
    /// The profile every installation can fall back to; it is never deleted.
    public static let defaultProfileName = "web"
    /// The bundle that must come first in a launchable profile.
    public static let baseBundle = "@deepseek-ai/dsh-base"
    /// The bundle that must follow ``baseBundle`` for the Web UI to start.
    public static let webBundle = "@deepseek-ai/dsh-web-app"

    /// The standardized `DSH_HOME` whose `profiles` directory is managed.
    public let dshHome: URL
    /// `DSH_HOME/profiles`, the only directory this store creates profiles in.
    public let profilesDirectory: URL
    /// Where the active, pending, and last-known-good selection is persisted.
    public let selectionStateURL: URL
    /// Where the recently used profile names are persisted.
    public let recentStateURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Creates a store for one `DSH_HOME`.
    ///
    /// - Parameters:
    ///   - dshHome: Harness data home; a non-standardized value is standardized here.
    ///   - supportDirectory: App support directory that holds this store's state.
    ///   - fileManager: File system seam used by tests.
    public init(
        dshHome: URL,
        supportDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.dshHome = dshHome.standardizedFileURL
        self.profilesDirectory = self.dshHome.appendingPathComponent("profiles", isDirectory: true)
        let stateDirectory = supportDirectory.standardizedFileURL
            .appendingPathComponent("HarnessProfiles", isDirectory: true)
            .appendingPathComponent(Self.stableIdentifier(for: self.dshHome.path), isDirectory: true)
        self.selectionStateURL = stateDirectory
            .appendingPathComponent("selection.json", isDirectory: false)
        self.recentStateURL = stateDirectory
            .appendingPathComponent("recent.json", isDirectory: false)
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        migrateLegacyStateIfNeeded(from: supportDirectory.standardizedFileURL)
    }

    /// Lists every profile discovered under ``profilesDirectory``.
    ///
    /// The default profile is added as a virtual entry when it has no directory yet,
    /// so callers always see at least one selectable profile.
    ///
    /// - Returns: Profiles sorted by localized name.
    public func profiles() -> [HarnessProfile] {
        var discovered: [HarnessProfile] = []
        if let entries = try? fileManager.contentsOfDirectory(
            at: profilesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            discovered = entries.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                      values.isDirectory == true else { return nil }
                return inspect(name: url.lastPathComponent)
            }
        }

        if !discovered.contains(where: { $0.name == Self.defaultProfileName }) {
            discovered.append(virtualDefaultProfile())
        }
        return discovered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Returns one profile by name.
    ///
    /// - Parameter name: Profile name; unsafe names return `nil`.
    /// - Returns: The profile, or `nil` when no such profile exists.
    public func profile(named name: String) -> HarnessProfile? {
        guard Self.isSafeName(name) else { return nil }
        if name == Self.defaultProfileName,
           !fileManager.fileExists(atPath: profileDirectory(name: name).path) {
            return virtualDefaultProfile()
        }
        return profiles().first { $0.name == name }
    }

    /// Lists profiles matching a case-insensitive query.
    ///
    /// The query is matched against the name, the bundle list, and any problem text.
    ///
    /// - Parameter query: Text to match; empty or `nil` returns every profile.
    /// - Returns: Matching profiles sorted by localized name.
    public func search(query: String? = nil) -> [HarnessProfile] {
        let normalized = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !normalized.isEmpty else { return profiles() }
        return profiles().filter { profile in
            profile.name.lowercased().contains(normalized)
                || profile.bundles.contains { $0.lowercased().contains(normalized) }
                || (profile.problem?.lowercased().contains(normalized) == true)
        }
    }

    /// Describes how a profile relates to the current selection.
    ///
    /// - Parameter name: Profile name.
    /// - Returns: The status, or ``HarnessProfileStatus/invalid`` when the profile is
    ///   missing or not selectable.
    public func status(for name: String) -> HarnessProfileStatus {
        guard let profile = profile(named: name), profile.selectable else { return .invalid }
        let selection = selection()
        if selection.active == name { return .active }
        if selection.pending == name { return .pending }
        if selection.lastKnownGood == name { return .lastKnownGood }
        return .ready
    }

    /// Lists profiles with recently used ones first.
    ///
    /// - Parameters:
    ///   - limit: Maximum number of profiles to return; values below zero yield none.
    ///   - query: Optional filter applied before ordering.
    /// - Returns: Recent profiles first, then the remaining matches by localized name.
    public func recentProfiles(limit: Int = 5, query: String? = nil) -> [HarnessProfile] {
        let candidates = search(query: query)
        let byName = Dictionary(uniqueKeysWithValues: candidates.map { ($0.name, $0) })
        let recent = recentNames().compactMap { byName[$0] }
        let remaining = candidates
            .filter { !recent.contains($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Array((recent + remaining).prefix(max(0, limit)))
    }

    /// Whether a profile appears in the persisted recent list.
    ///
    /// - Parameter name: Profile name.
    /// - Returns: `true` when the name was recorded recently.
    public func isRecentlyUsed(name: String) -> Bool {
        recentNames().contains(name)
    }

    /// Moves a profile to the front of the recent list, keeping the newest 20.
    ///
    /// Unknown names are ignored and a failed write is swallowed: usage history is a
    /// convenience, not a precondition for selecting a profile.
    ///
    /// - Parameter name: Profile name to record.
    public func recordUsage(name: String) {
        guard profile(named: name) != nil else { return }
        var names = recentNames().filter { $0 != name }
        names.insert(name, at: 0)
        names = Array(names.prefix(20))
        try? persistRecentNames(names)
    }

    /// Reads the persisted selection.
    ///
    /// - Returns: The stored selection, or a default selection naming the default
    ///   profile when the file is missing or invalid.
    public func selection() -> HarnessProfileSelection {
        guard let data = try? Data(contentsOf: selectionStateURL),
              let value = try? decoder.decode(HarnessProfileSelection.self, from: data),
              value.isValid else {
            return HarnessProfileSelection(
                active: Self.defaultProfileName,
                lastKnownGood: Self.defaultProfileName
            )
        }
        return value
    }

    /// Resolves which profile the next launch should use and persists the decision.
    ///
    /// A pending selection wins over the active one; when the requested profile is
    /// not selectable the last known good profile, or the default profile, is used
    /// instead.
    ///
    /// - Returns: The selection that startup should honor.
    public func startupProfile() -> HarnessProfileSelection {
        let current = selection()
        let requested = current.pending ?? current.active
        let requestedProfile = profile(named: requested)
        let fallback = profile(named: current.lastKnownGood)?.selectable == true
            ? current.lastKnownGood
            : Self.defaultProfileName
        let chosen = requestedProfile?.selectable == true ? requested : fallback
        let next = HarnessProfileSelection(
            active: chosen,
            lastKnownGood: profile(named: current.lastKnownGood)?.selectable == true
                ? current.lastKnownGood
                : Self.defaultProfileName
        )
        try? persist(next)
        return next
    }

    /// Creates a new profile directory with a minimal launcher manifest.
    ///
    /// The manifest, user patch, and workspace file are written into a staging
    /// directory first and then moved into place, so a failure cannot leave a
    /// half-created profile behind.
    ///
    /// - Parameter name: Profile name; must pass ``isSafeName(_:)``.
    /// - Returns: The created profile.
    /// - Throws: ``HarnessProfileStoreError`` when the name is invalid, the profile
    ///   already exists, or the manifest cannot be persisted.
    @discardableResult
    public func create(name: String) throws -> HarnessProfile {
        guard Self.isSafeName(name) else { throw HarnessProfileStoreError.invalidName }
        let target = profileDirectory(name: name)
        guard !fileManager.fileExists(atPath: target.path) else {
            throw HarnessProfileStoreError.alreadyExists
        }

        let staging = profilesDirectory.appendingPathComponent(
            ".\(name).creating-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            let manifest: [String: Any] = [
                "name": "dsh-profile-\(name)",
                "private": true,
                "dependencies": [:],
                "dsh": ["profile": ["bundles": [Self.baseBundle, Self.webBundle]]]
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: staging.appendingPathComponent("package.json"), options: .atomic)
            try Data("# DSH Studio Profile user patch\n[]\n".utf8)
                .write(to: staging.appendingPathComponent("cordis.patch.yml"), options: .atomic)
            try Data("packages:\n  - .\n\nnodeLinker: hoisted\nautoInstallPeers: false\n".utf8)
                .write(to: staging.appendingPathComponent("pnpm-workspace.yaml"), options: .atomic)
            try fileManager.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
            try fileManager.moveItem(at: staging, to: target)
        } catch let error as HarnessProfileStoreError {
            throw error
        } catch {
            try? fileManager.removeItem(at: staging)
            throw HarnessProfileStoreError.persistenceFailed(error.localizedDescription)
        }
        guard let created = profile(named: name) else { throw HarnessProfileStoreError.notFound }
        return created
    }

    /// Requests a profile for the next launch by recording it as pending.
    ///
    /// - Parameter name: Profile name to select.
    /// - Throws: ``HarnessProfileStoreError`` when the profile does not exist, is not
    ///   selectable, or the selection cannot be persisted.
    public func select(name: String) throws {
        guard let profile = profile(named: name) else { throw HarnessProfileStoreError.notFound }
        guard profile.selectable else {
            throw HarnessProfileStoreError.notSelectable(profile.problem ?? "配置不完整")
        }
        let current = selection()
        try persist(HarnessProfileSelection(
            active: current.active,
            pending: name == current.active ? nil : name,
            lastKnownGood: current.lastKnownGood
        ))
        recordUsage(name: name)
    }

    /// Records a profile as both active and last known good.
    ///
    /// Called after a successful start, so a later failure can fall back to a profile
    /// that is known to work.
    ///
    /// - Parameter name: Profile that started successfully.
    /// - Throws: ``HarnessProfileStoreError`` when the profile is not selectable or
    ///   the selection cannot be persisted.
    public func markHealthy(name: String) throws {
        guard profile(named: name)?.selectable == true else {
            throw HarnessProfileStoreError.notSelectable("配置不存在")
        }
        try persist(HarnessProfileSelection(active: name, lastKnownGood: name))
        recordUsage(name: name)
    }

    /// Restores the last known good profile as the active selection.
    ///
    /// - Returns: The name of the profile that was restored.
    /// - Throws: ``HarnessProfileStoreError`` when the selection cannot be persisted.
    public func rollbackToLastKnownGood() throws -> String {
        let current = selection()
        let fallback = profile(named: current.lastKnownGood)?.selectable == true
            ? current.lastKnownGood
            : Self.defaultProfileName
        try persist(HarnessProfileSelection(active: fallback, lastKnownGood: fallback))
        return fallback
    }

    /// Deletes a profile directory.
    ///
    /// The default profile and any profile referenced by the current selection are
    /// rejected. Deletion moves the directory aside first, so a failed removal can be
    /// rolled back.
    ///
    /// - Parameter name: Profile name to delete.
    /// - Throws: ``HarnessProfileStoreError`` when the profile is protected, missing,
    ///   or the directory cannot be removed.
    public func delete(name: String) throws {
        guard Self.isSafeName(name), name != Self.defaultProfileName else {
            throw HarnessProfileStoreError.cannotDeleteActive
        }
        let current = selection()
        guard current.active != name, current.pending != name, current.lastKnownGood != name else {
            throw HarnessProfileStoreError.cannotDeleteActive
        }
        let target = profileDirectory(name: name)
        guard isNonSymlinkDirectory(target) else {
            throw HarnessProfileStoreError.notFound
        }
        let staging = profilesDirectory.appendingPathComponent(
            ".\(name).deleting-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.moveItem(at: target, to: staging)
            try fileManager.removeItem(at: staging)
        } catch {
            if fileManager.fileExists(atPath: staging.path),
               !fileManager.fileExists(atPath: target.path) {
                try? fileManager.moveItem(at: staging, to: target)
            }
            throw HarnessProfileStoreError.persistenceFailed(error.localizedDescription)
        }
    }

    /// Whether a name may be used as a single profile directory component.
    ///
    /// Accepted form: 1–255 characters from `A-Z`, `a-z`, `0-9`, `-`, `_`, and `.`,
    /// starting with a letter or digit. Reserved names such as `..` and
    /// `node_modules` are rejected.
    ///
    /// - Parameter name: Candidate profile name.
    /// - Returns: `true` when the name is safe to use as a directory name.
    public static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              name != "node_modules",
              name.utf8.count <= 255,
              let first = name.utf8.first,
              (first >= 48 && first <= 57) || (first >= 65 && first <= 90) || (first >= 97 && first <= 122) else {
            return false
        }
        return name.utf8.dropFirst().allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
                || $0 == 45
                || $0 == 95
                || $0 == 46
        }
    }

    private func inspect(name: String) -> HarnessProfile? {
        guard Self.isSafeName(name) else { return nil }
        let directory = profileDirectory(name: name)
        guard isNonSymlinkDirectory(directory) else { return nil }
        let manifestURL = directory.appendingPathComponent("package.json")
        guard isNonSymlinkRegularFile(manifestURL) else {
            return HarnessProfile(name: name, directory: directory, bundles: [], exists: true, selectable: false, problem: "缺少 package.json")
        }
        guard let data = try? Data(contentsOf: manifestURL), data.count <= 2 * 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data),
              let manifest = object as? [String: Any] else {
            return HarnessProfile(name: name, directory: directory, bundles: [], exists: true, selectable: false, problem: "package.json 无法解析")
        }
        let bundles = (((manifest["dsh"] as? [String: Any])?["profile"] as? [String: Any])?["bundles"] as? [Any])?.compactMap { $0 as? String } ?? []
        guard bundles.count == (((manifest["dsh"] as? [String: Any])?["profile"] as? [String: Any])?["bundles"] as? [Any])?.count ?? 0 else {
            return HarnessProfile(name: name, directory: directory, bundles: bundles, exists: true, selectable: false, problem: "bundles 配置无效")
        }
        guard let baseIndex = bundles.firstIndex(of: Self.baseBundle),
              let webIndex = bundles.firstIndex(of: Self.webBundle),
              baseIndex < webIndex else {
            return HarnessProfile(name: name, directory: directory, bundles: bundles, exists: true, selectable: false, problem: "缺少可启动的 Web Profile 组件")
        }
        return HarnessProfile(name: name, directory: directory, bundles: bundles, exists: true, selectable: true)
    }

    private func virtualDefaultProfile() -> HarnessProfile {
        HarnessProfile(
            name: Self.defaultProfileName,
            directory: profileDirectory(name: Self.defaultProfileName),
            bundles: [Self.baseBundle, Self.webBundle],
            exists: false,
            selectable: true
        )
    }

    private func profileDirectory(name: String) -> URL {
        profilesDirectory.appendingPathComponent(name, isDirectory: true)
    }

    private func isNonSymlinkDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func isNonSymlinkRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func persist(_ selection: HarnessProfileSelection) throws {
        guard selection.isValid else { throw HarnessProfileStoreError.persistenceFailed("选择状态无效") }
        do {
            try fileManager.createDirectory(at: selectionStateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(selection)
            try data.write(to: selectionStateURL, options: .atomic)
        } catch {
            throw HarnessProfileStoreError.persistenceFailed(error.localizedDescription)
        }
    }

    private func recentNames() -> [String] {
        guard let data = try? Data(contentsOf: recentStateURL),
              let names = try? decoder.decode([String].self, from: data) else {
            return []
        }
        return names.filter(Self.isSafeName)
    }

    private func persistRecentNames(_ names: [String]) throws {
        guard names.allSatisfy(Self.isSafeName) else { return }
        try fileManager.createDirectory(
            at: recentStateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(names).write(to: recentStateURL, options: .atomic)
    }

    private func migrateLegacyStateIfNeeded(from supportDirectory: URL) {
        let legacyDirectory = supportDirectory.appendingPathComponent("HarnessProfiles", isDirectory: true)
        let legacyURLs = [
            (legacyDirectory.appendingPathComponent("selection.json", isDirectory: false), selectionStateURL),
            (legacyDirectory.appendingPathComponent("recent.json", isDirectory: false), recentStateURL)
        ]
        for (source, destination) in legacyURLs {
            guard !fileManager.fileExists(atPath: destination.path),
                  isNonSymlinkRegularFile(source) else { continue }
            do {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: source, to: destination)
                try? fileManager.removeItem(at: source)
            } catch {
                continue
            }
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
