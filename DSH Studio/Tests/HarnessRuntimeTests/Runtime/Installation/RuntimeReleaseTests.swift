import Foundation
import XCTest
@testable import DeepSeekRuntime

/// Guards the compiled fallback against the Runtime repository's versioning rules.
///
/// A Runtime's identity is the Harness version it contains, with no build counter:
/// the Runtime repository publishes and republishes under that one name, and the
/// artifact's bytes are identified by their SHA-256 instead. The signed catalog is
/// the authority for what a user installs, but this fallback is what a build
/// without a catalog resolves — and a fallback that names a version the publisher
/// never issued cannot be downloaded at all.
final class RuntimeReleaseTests: XCTestCase {
    /// The fallback names one Runtime, not two versions of it.
    ///
    /// `runtimeVersion` and `harnessVersion` are the same string by contract, and a
    /// fallback that disagreed would resolve Harness paths for a version the Runtime
    /// next to it does not contain.
    func testPinnedRuntimeIdentityIsTheHarnessVersion() {
        XCTAssertEqual(RuntimeRelease.runtimeVersion, RuntimeRelease.harnessVersion)
        XCTAssertEqual(RuntimeRelease.harnessVersion, RuntimeLocator.harnessVersion)
    }

    /// The retired `-ver<n>` counter is not used for new publications.
    ///
    /// The suffix is still *read* — installations and cached catalogs predate its
    /// retirement — but a freshly pinned fallback must not reintroduce it, because the
    /// publisher would then treat it as a repack of a version it already issued.
    func testPinnedRuntimeIdentityCarriesNoBuildCounter() {
        XCTAssertFalse(
            RuntimeRelease.runtimeVersion.contains("-ver"),
            "\(RuntimeRelease.runtimeVersion) uses the retired build counter"
        )
    }

    /// The pinned release is complete enough to install without a catalog.
    func testPinnedReleaseDescribesOneInstallableRuntime() throws {
        let release = try XCTUnwrap(RuntimeRelease.descriptor(architecture: "darwin-arm64"))

        XCTAssertEqual(release.runtimeVersion, RuntimeRelease.runtimeVersion)
        XCTAssertEqual(release.harnessVersion, RuntimeRelease.harnessVersion)
        XCTAssertEqual(release.nodeVersion, RuntimeRelease.nodeVersion)
        XCTAssertEqual(release.pnpmVersion, RuntimeRelease.pnpmVersion)
        XCTAssertTrue(release.harnessPackageIntegrity.hasPrefix("sha512-"))
        XCTAssertTrue(release.pnpmPackageIntegrity.hasPrefix("sha512-"))
        XCTAssertEqual(release.nodeArchiveSHA256.count, 64)
        XCTAssertEqual(release.dataFormat?.id, RuntimeRelease.dataFormat.id)
    }
}
