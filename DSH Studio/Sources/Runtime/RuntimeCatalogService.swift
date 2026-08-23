//
//  RuntimeCatalogService.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/21.
//

import CryptoKit
import Foundation

/// A signed wrapper around the catalog payload published by DSH Studio.
///
/// The payload is signed as raw bytes rather than re-encoded after decoding.
/// This keeps verification independent of JSON whitespace and key ordering.
public struct RuntimeSignedCatalog: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let keyID: String
    public let payload: String
    public let signature: String

    public init(
        schemaVersion: Int = currentSchemaVersion,
        keyID: String,
        payload: String,
        signature: String
    ) {
        self.schemaVersion = schemaVersion
        self.keyID = keyID
        self.payload = payload
        self.signature = signature
    }

    public func verifiedCatalog(
        publicKeyData: Data,
        expectedKeyID: String? = nil
    ) throws -> RuntimeReleaseCatalog {
        guard schemaVersion == Self.currentSchemaVersion,
              !keyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              expectedKeyID == nil || keyID == expectedKeyID,
              let payloadData = Data(base64Encoded: payload),
              let signatureData = Data(base64Encoded: signature) else {
            throw RuntimeCatalogError.invalidEnvelope
        }

        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        } catch {
            throw RuntimeCatalogError.invalidPublicKey
        }
        guard publicKey.isValidSignature(signatureData, for: payloadData) else {
            throw RuntimeCatalogError.signatureInvalid
        }
        do {
            return try RuntimeReleaseCatalog.decode(payloadData)
        } catch {
            throw RuntimeCatalogError.invalidCatalog
        }
    }

    #if DEBUG
    public static func signed(
        catalog: RuntimeReleaseCatalog,
        using privateKey: Curve25519.Signing.PrivateKey,
        keyID: String
    ) throws -> Self {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payloadData = try encoder.encode(catalog)
        let signatureData = try privateKey.signature(for: payloadData)
        return Self(
            keyID: keyID,
            payload: payloadData.base64EncodedString(),
            signature: signatureData.base64EncodedString()
        )
    }
    #endif
}

public enum RuntimeCatalogError: Error, Equatable, LocalizedError, Sendable {
    case invalidEnvelope
    case invalidPublicKey
    case signatureInvalid
    case invalidCatalog
    case unavailable
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEnvelope:
            return "Runtime catalog 签名封装无效"
        case .invalidPublicKey:
            return "Runtime catalog 公钥无效"
        case .signatureInvalid:
            return "Runtime catalog 签名校验失败"
        case .invalidCatalog:
            return "Runtime catalog 内容无效"
        case .unavailable:
            return "没有可用的 Runtime catalog"
        case .downloadFailed(let detail):
            return "Runtime catalog 下载失败：\(detail)"
        }
    }
}

public protocol RuntimeCatalogFetching: Sendable {
    func fetch(from url: URL) async throws -> Data
}

public struct URLSessionRuntimeCatalogFetcher: RuntimeCatalogFetching, Sendable {
    public init() {}

    public func fetch(from url: URL) async throws -> Data {
        guard RuntimeReleaseCatalog.isTrustedCatalogURL(url) else {
            throw RuntimeCatalogError.downloadFailed("catalog 地址不是受信任的官方地址")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RuntimeCatalogError.downloadFailed(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse,
              let finalURL = httpResponse.url,
              (200...299).contains(httpResponse.statusCode),
              (finalURL.host == "release-assets.githubusercontent.com"
                  || RuntimeReleaseCatalog.isTrustedCatalogURL(finalURL)) else {
            throw RuntimeCatalogError.downloadFailed("服务器返回了无效 HTTP 状态或重定向地址")
        }
        return data
    }
}

public enum RuntimeCatalogSource: String, Codable, Equatable, Sendable {
    case remote
    case cache
    case bundled
}

public struct RuntimeCatalogResolution: Equatable, Sendable {
    public let catalog: RuntimeReleaseCatalog
    public let release: RuntimeReleaseDescriptor
    public let source: RuntimeCatalogSource

    public init(
        catalog: RuntimeReleaseCatalog,
        release: RuntimeReleaseDescriptor,
        source: RuntimeCatalogSource
    ) {
        self.catalog = catalog
        self.release = release
        self.source = source
    }
}

/// Resolves the signed catalog from the independent Runtime repository and
/// keeps a verified local cache for offline startup. A bad network response
/// can never replace the last known-good cache.
public final class RuntimeCatalogService: @unchecked Sendable {
    public static let defaultRemoteURL = URL(
        string: "https://github.com/SteveTanSaMa/DSH-Studio-Runtime/releases/download/runtime-catalog/runtime-catalog.signed.json"
    )!

    private let supportDirectory: URL?
    private let bundle: Bundle
    private let architecture: String
    private let remoteURL: URL
    private let publicKeyData: Data?
    private let fetcher: any RuntimeCatalogFetching
    private let fileManager: FileManager

    public init(
        supportDirectory: URL?,
        bundle: Bundle = .main,
        architecture: String = RuntimeLocator.architectureDirectory(),
        remoteURL: URL? = nil,
        publicKeyData: Data? = nil,
        fetcher: any RuntimeCatalogFetching = URLSessionRuntimeCatalogFetcher(),
        fileManager: FileManager = .default
    ) {
        self.supportDirectory = supportDirectory?.standardizedFileURL
        self.bundle = bundle
        self.architecture = architecture
        self.remoteURL = remoteURL ?? RuntimeCatalogService.defaultRemoteURL
        self.publicKeyData = publicKeyData ?? RuntimeCatalogTrust.publicKeyData(bundle: bundle)
        self.fetcher = fetcher
        self.fileManager = fileManager
    }

    public func bundledResolution() -> RuntimeCatalogResolution? {
        guard let catalog = try? RuntimeReleaseCatalog.loadCatalog(bundle: bundle),
              let release = catalog.release(for: architecture) else {
            return nil
        }
        return RuntimeCatalogResolution(catalog: catalog, release: release, source: .bundled)
    }

    /// Resolves only catalogs that have passed the configured Ed25519
    /// signature check. The unsigned bundled catalog is deliberately excluded
    /// because it is not authoritative for the latest-version display.
    public func signedResolution() async throws -> RuntimeCatalogResolution {
        guard let publicKeyData else {
            throw RuntimeCatalogError.unavailable
        }

        var candidates: [RuntimeCatalogResolution] = []
        var cached: RuntimeCatalogResolution?
        if let cachedData = loadCacheData(),
           let verifiedCache = try? verifiedResolution(
               data: cachedData,
               source: .cache,
               publicKeyData: publicKeyData
           ) {
            cached = verifiedCache
            candidates.append(verifiedCache)
        }

        do {
            let data = try await fetcher.fetch(from: remoteURL)
            if let remote = try? verifiedResolution(
                data: data,
                source: .remote,
                publicKeyData: publicKeyData
            ), !hasConflictingKnownRelease(remote, candidates: candidates) {
                if isAtLeast(remote.release.runtimeVersion, cached?.release.runtimeVersion) {
                    persistCache(data: data)
                }
                candidates.append(remote)
            }
        } catch {
            // A verified cache remains usable when the network is unavailable.
        }

        guard let first = candidates.first else {
            throw RuntimeCatalogError.unavailable
        }
        return candidates.dropFirst().reduce(first) { current, candidate in
            isPreferred(candidate, over: current) ? candidate : current
        }
    }

    public func resolve() async throws -> RuntimeCatalogResolution {
        let bundled = bundledResolution()

        guard let publicKeyData else {
            if let bundled { return bundled }
            throw RuntimeCatalogError.unavailable
        }

        var candidates: [RuntimeCatalogResolution] = []
        if let bundled {
            candidates.append(bundled)
        }
        var cached: RuntimeCatalogResolution?
        if let cachedData = loadCacheData() {
            let verifiedCache = try? verifiedResolution(
                data: cachedData,
                source: .cache,
                publicKeyData: publicKeyData
            )
            if let verifiedCache,
               !hasConflictingKnownRelease(verifiedCache, candidates: candidates) {
                cached = verifiedCache
                candidates.append(verifiedCache)
            }
        }

        do {
            let data = try await fetcher.fetch(from: remoteURL)
            if let remote = try? verifiedResolution(
                data: data,
                source: .remote,
                publicKeyData: publicKeyData
            ) {
                if !hasConflictingKnownRelease(remote, candidates: candidates) {
                    if isAtLeast(remote.release.runtimeVersion, bundled?.release.runtimeVersion),
                       isAtLeast(remote.release.runtimeVersion, cached?.release.runtimeVersion) {
                        persistCache(data: data)
                    }
                    candidates.append(remote)
                }
            }
        } catch {
            // A remote failure falls through to the verified cache or the
            // bundled catalog. Startup must remain usable offline.
        }

        guard let first = candidates.first else {
            throw RuntimeCatalogError.unavailable
        }
        let best = candidates.dropFirst().reduce(first) { current, candidate in
            isPreferred(candidate, over: current) ? candidate : current
        }
        return best
    }

    private func hasConflictingKnownRelease(
        _ candidate: RuntimeCatalogResolution,
        candidates: [RuntimeCatalogResolution]
    ) -> Bool {
        candidates.contains {
            $0.release.runtimeVersion == candidate.release.runtimeVersion
                && $0.release != candidate.release
        }
    }

    private func verifiedResolution(
        data: Data,
        source: RuntimeCatalogSource,
        publicKeyData: Data
    ) throws -> RuntimeCatalogResolution {
        let envelope = try JSONDecoder().decode(RuntimeSignedCatalog.self, from: data)
        let catalog = try envelope.verifiedCatalog(
            publicKeyData: publicKeyData,
            expectedKeyID: RuntimeCatalogTrust.keyID
        )
        guard let release = catalog.release(for: architecture) else {
            throw RuntimeCatalogError.invalidCatalog
        }
        return RuntimeCatalogResolution(catalog: catalog, release: release, source: source)
    }

    private func loadCacheData() -> Data? {
        guard let supportDirectory else { return nil }
        let url = supportDirectory
            .appendingPathComponent("RuntimeManifest", isDirectory: true)
            .appendingPathComponent("runtime-catalog.signed.json", isDirectory: false)
        return try? Data(contentsOf: url)
    }

    private func persistCache(data: Data) {
        guard let supportDirectory, !data.isEmpty else { return }
        let directory = supportDirectory.appendingPathComponent("RuntimeManifest", isDirectory: true)
        let url = directory.appendingPathComponent("runtime-catalog.signed.json", isDirectory: false)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
    }

    private func isAtLeast(_ candidate: String, _ baseline: String?) -> Bool {
        guard let baseline else { return true }
        return RuntimeVersionOrdering.compare(candidate, baseline) != .orderedAscending
    }

    private func isPreferred(
        _ candidate: RuntimeCatalogResolution,
        over current: RuntimeCatalogResolution
    ) -> Bool {
        switch RuntimeVersionOrdering.compare(
            candidate.release.runtimeVersion,
            current.release.runtimeVersion
        ) {
        case .orderedDescending:
            return true
        case .orderedAscending:
            return false
        case .orderedSame:
            return sourcePriority(candidate.source) > sourcePriority(current.source)
        }
    }

    private func sourcePriority(_ source: RuntimeCatalogSource) -> Int {
        switch source {
        case .bundled:
            return 0
        case .cache:
            return 1
        case .remote:
            return 2
        }
    }
}

public enum RuntimeCatalogTrust {
    public static let publicKeyInfoPlistKey = "RuntimeCatalogPublicKey"
    public static let keyID = "runtime-catalog-v1"

    public static func publicKeyData(bundle: Bundle = .main) -> Data? {
        guard let value = bundle.object(forInfoDictionaryKey: publicKeyInfoPlistKey) as? String else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !normalized.hasPrefix("$(") else { return nil }
        return Data(base64Encoded: normalized)
    }
}

public enum RuntimeVersionOrdering {
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let left = standardizedRuntimeVersion(lhs),
           let right = standardizedRuntimeVersion(rhs) {
            let harnessResult = compareHarnessVersions(left.harness, right.harness)
            if harnessResult != .orderedSame {
                return harnessResult
            }
            return left.revision == right.revision
                ? .orderedSame
                : (left.revision < right.revision ? .orderedAscending : .orderedDescending)
        }
        if standardizedRuntimeVersion(lhs) != nil {
            return .orderedDescending
        }
        if standardizedRuntimeVersion(rhs) != nil {
            return .orderedAscending
        }

        let left = components(lhs)
        let right = components(rhs)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : ""
            let r = index < right.count ? right[index] : ""
            if let ln = Int(l), let rn = Int(r), ln != rn {
                return ln < rn ? .orderedAscending : .orderedDescending
            }
            if l != r {
                return l.localizedStandardCompare(r)
            }
        }
        return .orderedSame
    }

    private static func components(_ value: String) -> [String] {
        value.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func standardizedRuntimeVersion(_ value: String) -> (harness: String, revision: Int)? {
        guard let range = value.range(of: #"-ver[1-9][0-9]*$"#, options: .regularExpression),
              let revision = Int(value[range].dropFirst(4)) else {
            return nil
        }
        let harness = String(value[..<range.lowerBound])
        guard !harness.isEmpty else { return nil }
        return (harness, revision)
    }

    private static func compareHarnessVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = parseHarnessVersion(lhs)
        let right = parseHarnessVersion(rhs)
        guard let left, let right else {
            return compareComponents(components(lhs), components(rhs))
        }

        for (l, r) in zip(left.core, right.core) where l != r {
            return l < r ? .orderedAscending : .orderedDescending
        }
        if left.core.count != right.core.count {
            return left.core.count < right.core.count ? .orderedAscending : .orderedDescending
        }
        switch (left.prerelease, right.prerelease) {
        case (nil, nil):
            return .orderedSame
        case (nil, _):
            return .orderedDescending
        case (_, nil):
            return .orderedAscending
        case let (left?, right?):
            return comparePrerelease(left, right)
        }
    }

    private static func compareComponents(_ lhs: [String], _ rhs: [String]) -> ComparisonResult {
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : ""
            let r = index < rhs.count ? rhs[index] : ""
            if let ln = Int(l), let rn = Int(r), ln != rn {
                return ln < rn ? .orderedAscending : .orderedDescending
            }
            if l != r {
                return l.localizedStandardCompare(r)
            }
        }
        return .orderedSame
    }

    private static func parseHarnessVersion(_ value: String) -> (core: [Int], prerelease: [String]?)? {
        let parts = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: true)
        let withoutBuild = parts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
        let coreParts = withoutBuild[0].split(separator: ".", omittingEmptySubsequences: false)
        let core = coreParts.compactMap { Int($0) }
        guard coreParts.count == 3, core.count == 3 else {
            return nil
        }
        let prerelease = withoutBuild.count == 2
            ? withoutBuild[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            : nil
        return (core, prerelease)
    }

    private static func comparePrerelease(_ lhs: [String], _ rhs: [String]) -> ComparisonResult {
        for index in 0..<max(lhs.count, rhs.count) {
            guard index < lhs.count else { return .orderedAscending }
            guard index < rhs.count else { return .orderedDescending }
            let left = lhs[index]
            let right = rhs[index]
            if left == right { continue }
            if let ln = Int(left), let rn = Int(right) {
                return ln < rn ? .orderedAscending : .orderedDescending
            }
            if Int(left) != nil { return .orderedAscending }
            if Int(right) != nil { return .orderedDescending }
            return left.localizedStandardCompare(right)
        }
        return .orderedSame
    }
}
