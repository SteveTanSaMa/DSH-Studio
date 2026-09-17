//
//  RuntimeCatalogService.swift
//  DSH Studio
//

import Foundation

/// Where a resolved catalog came from.
public enum RuntimeCatalogSource: String, Codable, Equatable, Sendable {
    /// Fetched from the signed remote catalog and verified.
    case remote
    /// Restored from the verified local cache.
    case cache
    /// Shipped inside the app bundle.
    case bundled
}

/// A catalog together with the release selected for this Mac.
public struct RuntimeCatalogResolution: Equatable, Sendable {
    /// The catalog the release came from.
    public let catalog: RuntimeReleaseCatalog
    /// The release selected for the requested architecture.
    public let release: RuntimeReleaseDescriptor
    /// How the catalog was obtained.
    public let source: RuntimeCatalogSource

    /// Creates a resolution.
    ///
    /// - Parameters:
    ///   - catalog: Catalog the release came from.
    ///   - release: Release selected for the architecture.
    ///   - source: How the catalog was obtained.
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

/// Resolves the signed catalog and keeps a verified cache for offline startup.
///
/// A network response that fails verification can never replace the last
/// known-good cache.
public final class RuntimeCatalogService: @unchecked Sendable {
    /// The signed catalog published by the Runtime repository.
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

    /// Creates a catalog service.
    ///
    /// - Parameters:
    ///   - supportDirectory: App support directory used for the verified cache.
    ///   - bundle: Bundle containing the bundled catalog and trust key.
    ///   - architecture: Architecture to resolve; defaults to this host's.
    ///   - remoteURL: Catalog URL override, mainly for tests.
    ///   - publicKeyData: Ed25519 public key override; resolved from the bundle by
    ///     default.
    ///   - fetcher: Network seam used to download the catalog.
    ///   - fileManager: File system seam used by tests.
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

    /// Resolves the catalog shipped inside the app bundle.
    ///
    /// - Returns: The bundled resolution, or `nil` when the bundle has no usable
    ///   entry for this architecture.
    public func bundledResolution() -> RuntimeCatalogResolution? {
        guard let catalog = try? RuntimeReleaseCatalog.loadCatalog(bundle: bundle),
              let release = catalog.release(for: architecture) else {
            return nil
        }
        return RuntimeCatalogResolution(catalog: catalog, release: release, source: .bundled)
    }

    /// Resolves only catalogs that passed the configured Ed25519 signature check.
    ///
    /// The unsigned bundled catalog is deliberately excluded because it is not
    /// authoritative for the latest-version display.
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

    /// Resolves the best available catalog: remote, then cache, then bundled.
    ///
    /// A response that fails signature verification is discarded, so the last
    /// known-good cache stays authoritative when the network is unavailable or
    /// serves unexpected content.
    ///
    /// - Returns: The preferred resolution for this architecture.
    /// - Throws: ``RuntimeCatalogError/unavailable`` when no source yields a usable
    ///   release, or the verification error for a rejected remote payload.
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
