import Foundation
import XCTest
@testable import DeepSeekRuntime

/// Guards the contract that keeps the market usable across Runtime updates.
///
/// The market version used to be a constant compiled into the app, so a Runtime that
/// moved to a newer Harness could strand it: the runtime data is signed and follows
/// the Runtime, the market was frozen. These tests pin both halves of the fix — the
/// pin travels with the Runtime release, and compatibility is decided from the range
/// the market itself declares.
final class PluginMarketPinTests: XCTestCase {

    // MARK: - Compatibility range

    /// The range the market publishes decides support, including its prereleases.
    func testDeclaredRangeDecidesSupport() {
        // The production case: 1.62.0 listed ^0.1.x only, and a Runtime moved to 0.2.
        let legacy = "^0.1.0-rc.7 || ^0.1.1-rc.2 || ^0.1.2-alpha.2"
        XCTAssertEqual(PluginCompatibility.satisfies("0.2.0-rc.1", range: legacy), false)
        XCTAssertEqual(PluginCompatibility.satisfies("0.1.7-rc.2", range: legacy), true)
        XCTAssertEqual(PluginCompatibility.satisfies("0.1.0-rc.6", range: legacy), false)

        let current = "\(legacy) || ^0.2.0-rc.1"
        XCTAssertEqual(PluginCompatibility.satisfies("0.2.0-rc.1", range: current), true)
        XCTAssertEqual(PluginCompatibility.satisfies("0.1.7-rc.2", range: current), true)
        XCTAssertEqual(PluginCompatibility.satisfies("0.3.0-rc.1", range: current), false)
    }

    /// A prerelease is judged on its line, unless the range names that very build.
    ///
    /// A plugin author writing `^0.1.1-rc.2` means the 0.1 line from that build on; read
    /// strictly, every 0.1.x Harness build would fall outside a range that plainly
    /// covers it. A comparator naming the same `major.minor.patch` keeps the prerelease
    /// order, so an older build of that same line is still rejected.
    func testPrereleasesAreJudgedOnTheirLine() {
        XCTAssertEqual(PluginCompatibility.satisfies("0.1.6-alpha.2", range: "^0.1.0-rc.7"), true)
        XCTAssertEqual(PluginCompatibility.satisfies("0.1.0-rc.6", range: "^0.1.0-rc.7"), false)
        XCTAssertEqual(PluginCompatibility.satisfies("0.2.0-rc.1", range: "^0.2.0-rc.1"), true)
        XCTAssertEqual(PluginCompatibility.satisfies("0.2.0-beta.1", range: "^0.2.0-rc.1"), false)
        XCTAssertEqual(PluginCompatibility.satisfies("0.2.0", range: "^0.2.0-rc.1"), true)
        // The boundary that matters: a prerelease of the next line is not covered.
        XCTAssertEqual(PluginCompatibility.satisfies("0.2.0-rc.1", range: "^0.1.2-alpha.2"), false)
    }

    /// The operators a plugin range may use all behave as npm defines them.
    func testSupportedOperators() {
        XCTAssertEqual(PluginCompatibility.satisfies("0.1.5", range: "~0.1.2"), true)
        XCTAssertEqual(PluginCompatibility.satisfies("0.2.0", range: "~0.1.2"), false)
        XCTAssertEqual(PluginCompatibility.satisfies("1.2.3", range: "^1.2.3"), true)
        XCTAssertEqual(PluginCompatibility.satisfies("2.0.0", range: "^1.2.3"), false)
        XCTAssertEqual(PluginCompatibility.satisfies("0.3.0", range: "0.0.3"), false)
        XCTAssertEqual(PluginCompatibility.satisfies("0.0.30", range: ">=0.0.3 <0.0.4"), false)
        XCTAssertEqual(PluginCompatibility.satisfies("0.1.5", range: ">=0.1.2 <0.2.0"), true)
        XCTAssertEqual(PluginCompatibility.satisfies("0.2.0", range: ">=0.1.2 <0.2.0"), false)
        XCTAssertEqual(PluginCompatibility.satisfies("0.2.0-rc.1", range: "0.2.0-rc.1"), true)
        XCTAssertEqual(PluginCompatibility.satisfies("0.2.0", range: "0.2.0-rc.1"), false)
        // Build metadata is not part of the comparison.
        XCTAssertEqual(PluginCompatibility.satisfies("1.2.3+build.5", range: "^1.2.3"), true)
    }

    /// A range the app cannot read reports undecidable instead of a verdict.
    func testUnreadableRangesAreUndecidable() {
        XCTAssertNil(PluginCompatibility.satisfies("0.2.0-rc.1", range: "latest"))
        XCTAssertNil(PluginCompatibility.satisfies("0.2.0-rc.1", range: "^0.2.0 || "))
        XCTAssertNil(PluginCompatibility.satisfies("0.2.0-rc.1", range: "^abc"))
        XCTAssertNil(PluginCompatibility.satisfies("0.2.0-rc.1", range: "^0.2.0, <0.3.0"))
        XCTAssertNil(PluginCompatibility.satisfies("not-a-version", range: "^0.2.0"))
    }

    /// An undecidable range is not a rejection, so an unknown spelling never blocks.
    func testUndecidableRangeIsNotARejection() {
        let pin = RuntimePluginPin(
            package: "dshmarket",
            version: "1.0.0",
            integrity: "sha512-fixture",
            harnessRange: "works-with-everything"
        )
        XCTAssertTrue(PluginMarketRelease.isCompatible(harness: "0.2.0-rc.1", pin: pin))
    }

    /// The installed package's declaration stands in when the publication carried none.
    func testInstalledPackageDeclarationStandsIn() {
        let pin = RuntimePluginPin(package: "dshmarket", version: "1.0.0", integrity: "sha512-fixture")
        XCTAssertTrue(PluginMarketRelease.isCompatible(
            harness: "0.1.7-rc.2",
            pin: pin,
            declaredRange: "^0.1.1-rc.2"
        ))
        XCTAssertFalse(PluginMarketRelease.isCompatible(
            harness: "0.2.0-rc.1",
            pin: pin,
            declaredRange: "^0.1.1-rc.2"
        ))
    }

    /// The compiled fallback must cover the Harness line the app itself ships.
    ///
    /// This is the guard for the failure that started all of this: refreshing one of the
    /// two pins without the other left the app unable to install its own market.
    func testFallbackPinCoversThePinnedHarnessLine() {
        XCTAssertTrue(
            PluginMarketRelease.isCompatible(
                harness: RuntimeRelease.harnessVersion,
                pin: PluginMarketRelease.fallbackPin
            ),
            "the fallback market pin no longer supports \(RuntimeRelease.harnessVersion)"
        )
    }

    // MARK: - Pin resolution

    /// The installed Runtime's own pin is what the profile is validated against.
    func testInstalledRuntimePinWins() {
        let installed = manifest(runtimeVersion: "0.2.0-rc.1", pin: pin(version: "1.66.5"))
        let available = release(runtimeVersion: "0.3.0-rc.1", pin: pin(version: "1.70.0"))

        let resolved = PluginMarketRelease.pin(installed: installed, available: available)

        XCTAssertEqual(resolved.version, "1.66.5")
    }

    /// A catalog entry stands in while nothing is installed yet.
    func testCatalogPinStandsInForAFreshInstall() {
        let available = release(runtimeVersion: "0.2.0-rc.1", pin: pin(version: "1.66.5"))

        let resolved = PluginMarketRelease.pin(installed: nil, available: available)

        XCTAssertEqual(resolved.version, "1.66.5")
    }

    /// A catalog for a *different* Runtime never supplies the pin for this one.
    ///
    /// The catalog describes exactly one Runtime version; taking its market pin while an
    /// older Runtime is installed would install the market for a Harness that is not
    /// running.
    func testCatalogPinForAnotherRuntimeIsIgnored() {
        let installed = manifest(runtimeVersion: "0.1.7-rc.2", pin: nil)
        let available = release(runtimeVersion: "0.2.0-rc.1", pin: pin(version: "1.66.5"))

        let resolved = PluginMarketRelease.pin(installed: installed, available: available)

        XCTAssertEqual(resolved.version, PluginMarketRelease.packageVersion)
        XCTAssertEqual(resolved, PluginMarketRelease.fallbackPin)
    }

    /// A publication that predates the field leaves the compiled pin in charge.
    func testFallbackIsUsedWhenNothingPublishesAPin() {
        let installed = manifest(runtimeVersion: "0.1.7-rc.2", pin: nil)
        let available = release(runtimeVersion: "0.1.7-rc.2", pin: nil)

        XCTAssertEqual(
            PluginMarketRelease.pin(installed: installed, available: available),
            PluginMarketRelease.fallbackPin
        )
        XCTAssertEqual(PluginMarketRelease.pin(installed: nil, available: nil), PluginMarketRelease.fallbackPin)
    }

    /// A signed catalog release carries the pin all the way into the descriptor.
    func testCatalogDecodesThePublishedPin() throws {
        let payload = """
        {
          "schemaVersion": 1,
          "runtimeVersion": "0.2.0-rc.1",
          "releases": [{
            "architecture": "darwin-arm64",
            "runtimeVersion": "0.2.0-rc.1",
            "nodeVersion": "24.19.0",
            "harnessVersion": "0.2.0-rc.1",
            "pnpmVersion": "11.22.0",
            "nodeArchiveSHA256": "8294b7aa9b03997481c06babf1e8b270c859358f27da57a11509afe537ac381d",
            "harnessPackageIntegrity": "sha512-fixture",
            "pnpmPackageIntegrity": "sha512-fixture",
            "dataFormat": {"id": "sqlite-v2", "compatibleWith": [], "migration": null},
            "pluginMarket": {
              "package": "dshmarket",
              "version": "1.66.5",
              "integrity": "sha512-market",
              "harnessRange": "^0.1.1-rc.2 || ^0.2.0-rc.1"
            },
            "artifact": {
              "runtimeVersion": "0.2.0-rc.1",
              "architecture": "darwin-arm64",
              "url": "https://github.com/SteveTanSaMa/DSH-Studio-Runtime/releases/download/runtime-0.2.0-rc.1/dsh-runtime-0.2.0-rc.1-darwin-arm64.tar.gz",
              "sha256": "c9d146694728748f285de37dee7db1a31eb7ef221f6fb073ad3b327130a7406e"
            }
          }]
        }
        """

        let catalog = try RuntimeReleaseCatalog.decode(Data(payload.utf8))
        let release = try XCTUnwrap(catalog.release(for: "darwin-arm64"))

        XCTAssertEqual(release.pluginMarket?.version, "1.66.5")
        XCTAssertEqual(release.pluginMarket?.integrity, "sha512-market")
        XCTAssertEqual(release.pluginMarket?.harnessRange, "^0.1.1-rc.2 || ^0.2.0-rc.1")
    }

    /// An installation record carries its pin, and version equality ignores it.
    func testManifestDecodesAndKeepsItsPin() throws {
        let payload = """
        {
          "schemaVersion": 3,
          "runtimeVersion": "0.2.0-rc.1",
          "architecture": "darwin-arm64",
          "nodeVersion": "24.19.0",
          "harnessVersion": "0.2.0-rc.1",
          "pnpmVersion": "11.22.0",
          "nodeSHA256": "8294b7aa9b03997481c06babf1e8b270c859358f27da57a11509afe537ac381d",
          "harnessPackageIntegrity": "sha512-fixture",
          "pnpmPackageIntegrity": "sha512-fixture",
          "pluginMarket": {"package": "dshmarket", "version": "1.66.5", "integrity": "sha512-market"}
        }
        """

        let manifest = try JSONDecoder().decode(RuntimeInstallationManifest.self, from: Data(payload.utf8))

        XCTAssertEqual(manifest.pluginMarket?.version, "1.66.5")
        // The pin describes a companion package, not the installed bytes, so it must not
        // invalidate an installation that otherwise matches its release.
        XCTAssertTrue(manifest.matches(RuntimeReleaseDescriptor(manifest: manifest)))
    }

    // MARK: - Applied to the profile

    /// The profile is validated against the Runtime's pin, not the compiled fallback.
    ///
    /// This is the whole point of the change: a Runtime that publishes its own market
    /// version must be able to move the market with it, and the checks that used to
    /// compare against a constant have to follow.
    func testStoreValidatesAgainstTheGivenPin() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let published = RuntimePluginPin(
            package: "dshmarket",
            version: "1.70.0",
            integrity: "sha512-published",
            harnessRange: "^0.3.0"
        )
        try writeProfile(in: home, version: "1.70.0", integrity: "sha512-published")

        let matching = PluginMarketProfileStore(dshHome: home, pin: published)
        XCTAssertNoThrow(try matching.validateExpectedInstallation())
        XCTAssertTrue(try matching.hasExpectedLockIntegrity())

        let fallback = PluginMarketProfileStore(dshHome: home, pin: PluginMarketRelease.fallbackPin)
        XCTAssertThrowsError(try fallback.validateExpectedInstallation())
        XCTAssertFalse(try fallback.hasExpectedLockIntegrity())
    }

    /// The manager takes the pin from the Runtime record it is bound to.
    @MainActor
    func testManagerAdoptsTheRuntimePublishedPin() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("Runtime", isDirectory: true)
        let harnessVersion = "0.3.0-rc.1"
        try writeInstalledRuntime(root: root, harnessVersion: harnessVersion)
        let published = RuntimePluginPin(
            package: "dshmarket",
            version: "1.70.0",
            integrity: "sha512-published",
            harnessRange: "^0.3.0-rc.1"
        )
        let status = RuntimeVersionStatus(
            kind: .current,
            installed: RuntimeInstallationManifest(
                runtimeVersion: "0.3.0-rc.1",
                architecture: "darwin-arm64",
                nodeVersion: "24.19.0",
                harnessVersion: harnessVersion,
                nodeSHA256: "8294b7aa9b03997481c06babf1e8b270c859358f27da57a11509afe537ac381d",
                harnessPackageIntegrity: "sha512-fixture",
                pluginMarket: published
            ),
            available: release(runtimeVersion: "0.3.0-rc.1", pin: published),
            rollbackAvailable: false
        )
        let runtime = RuntimeManager(
            configuration: RuntimeConfiguration(
                nodeExecutable: RuntimeLocator.nodeExecutable(root: root, architecture: "darwin-arm64"),
                harnessEntry: RuntimeLocator.harnessEntry(
                    root: root,
                    architecture: "darwin-arm64",
                    harnessVersion: harnessVersion
                ),
                dshHome: home,
                workspace: home,
                expectedHarnessVersion: harnessVersion
            ),
            updater: StubRuntimeUpdater(root: root, status: status)
        )

        let manager = PluginMarketManager(runtime: runtime, supportDirectory: home)

        XCTAssertEqual(manager.pin, published)
        XCTAssertEqual(manager.profileStore.pin, published)
        XCTAssertEqual(manager.state.requestedVersion, "1.70.0")
        XCTAssertEqual(manager.state.integrity, "sha512-published")
        XCTAssertTrue(manager.state.compatibleHarness)
    }

    // MARK: - Fixtures

    /// Writes the leaf files a Runtime manager reads its versions from.
    private func writeInstalledRuntime(root: URL, harnessVersion: String) throws {
        let node = RuntimeLocator.nodeExecutable(root: root, architecture: "darwin-arm64")
        try FileManager.default.createDirectory(
            at: node.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\necho v24.19.0\n".utf8).write(to: node)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: node.path
        )

        let harness = RuntimeLocator.harnessEntry(
            root: root,
            architecture: "darwin-arm64",
            harnessVersion: harnessVersion
        )
        try FileManager.default.createDirectory(
            at: harness.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/usr/bin/env node\n".utf8).write(to: harness)
        try Data("{\"name\":\"@deepseek-ai/dsh\",\"version\":\"\(harnessVersion)\"}".utf8)
            .write(to: harness.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("package.json"))
    }

    /// Writes a profile holding one market version with its integrity.
    private func writeProfile(in home: URL, version: String, integrity: String) throws {
        let profile = home
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("web", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: profile, withIntermediateDirectories: true)
        try write(
            "{\"dependencies\":{\"dshmarket\":\"\(version)\"},\"dsh\":{\"profile\":{\"bundles\":[\"dshmarket\"]}}}",
            to: profile.appendingPathComponent("package.json")
        )
        try write(
            "{\"name\":\"dshmarket\",\"version\":\"\(version)\",\"main\":\"lib/index.js\",\"dsh\":{\"bundle\":{\"patch\":\"./cordis.patch.yml\"}}}",
            to: profile.appendingPathComponent("node_modules/dshmarket/package.json")
        )
        try write(
            "// bundled entry",
            to: profile.appendingPathComponent("node_modules/dshmarket/lib/index.js")
        )
        try write(
            "# dsh bundle patch: inserts this plugin into a profile's layer stack.\n- insert:\n    - id: dsh-market\n      name: 'dshmarket'\n",
            to: profile.appendingPathComponent("node_modules/dshmarket/cordis.patch.yml")
        )
        try write(
            "lockfileVersion: '9.0'\npackages:\n  dshmarket@\(version):\n    resolution: {}\n    integrity: \(integrity)\n",
            to: profile.appendingPathComponent("pnpm-lock.yaml")
        )
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSHStudio-PluginMarketPin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pin(version: String) -> RuntimePluginPin {
        RuntimePluginPin(
            package: "dshmarket",
            version: version,
            integrity: "sha512-fixture",
            harnessRange: "^0.1.1-rc.2 || ^0.2.0-rc.1"
        )
    }

    private func release(runtimeVersion: String, pin: RuntimePluginPin?) -> RuntimeReleaseDescriptor {
        RuntimeReleaseDescriptor(
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            // A Runtime's identity is the Harness version it contains.
            harnessVersion: runtimeVersion,
            pnpmVersion: "11.22.0",
            nodeArchiveSHA256: "8294b7aa9b03997481c06babf1e8b270c859358f27da57a11509afe537ac381d",
            harnessPackageIntegrity: "sha512-fixture",
            pnpmPackageIntegrity: "sha512-fixture",
            runtimeVersion: runtimeVersion,
            dataFormat: RuntimeDataFormatDescriptor(id: "sqlite-v2"),
            pluginMarket: pin
        )
    }

    private func manifest(runtimeVersion: String, pin: RuntimePluginPin?) -> RuntimeInstallationManifest {
        RuntimeInstallationManifest(
            runtimeVersion: runtimeVersion,
            architecture: "darwin-arm64",
            nodeVersion: "24.19.0",
            harnessVersion: runtimeVersion,
            nodeSHA256: "8294b7aa9b03997481c06babf1e8b270c859358f27da57a11509afe537ac381d",
            harnessPackageIntegrity: "sha512-fixture",
            pluginMarket: pin
        )
    }
}

/// A Runtime whose release record is fixed, so a test can decide the market pin.
private final class StubRuntimeUpdater: RuntimeUpdating, @unchecked Sendable {
    let root: URL
    let architecture = "darwin-arm64"
    /// Accepted for protocol conformance; this stub never installs anything.
    var progressHandler: (@Sendable (RuntimeProvisioningProgress) -> Void)?
    private let status: RuntimeVersionStatus

    /// Creates a fixed Runtime record.
    ///
    /// - Parameters:
    ///   - root: Installation root to report.
    ///   - status: Comparison the record always answers with.
    init(root: URL, status: RuntimeVersionStatus) {
        self.root = root
        self.status = status
    }

    /// Reports the fixed comparison.
    ///
    /// - Returns: The status the test configured.
    func versionStatus() -> RuntimeVersionStatus {
        status
    }

    /// Never called: these tests exercise reads, not installation.
    ///
    /// - Throws: ``RuntimeProvisioningError/runtimeArtifactUnavailable``.
    func provision() async throws -> RuntimeProvisioningResult {
        throw RuntimeProvisioningError.runtimeArtifactUnavailable
    }

    /// Never called: these tests exercise reads, not updates.
    ///
    /// - Throws: ``RuntimeProvisioningError/runtimeArtifactUnavailable``.
    func update() async throws -> RuntimeProvisioningResult {
        throw RuntimeProvisioningError.runtimeArtifactUnavailable
    }

    /// Never called: these tests exercise reads, not rollback.
    ///
    /// - Throws: ``RuntimeProvisioningError/rollbackUnavailable``.
    func rollback() throws -> RuntimeProvisioningResult {
        throw RuntimeProvisioningError.rollbackUnavailable
    }
}
