import Foundation
import XCTest
@testable import DeepSeekRuntime

/// Native-dependency cases: what Harness loads has to work with the Node the Runtime
/// ships, not with whatever the build machine happens to have.
extension RuntimeProvisionerTests {

    /// The local install compiles the native module and keeps only its binding.
    func testLocalInstallBuildsNativeBindingAndPrunesBuildMaterial() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Runtime", isDirectory: true)
        let provisioner = RuntimeProvisioner(
            root: root,
            architecture: architecture,
            downloader: FixtureDownloader(data: Data("node archive fixture".utf8)),
            commandRunner: FixtureCommandRunner(includesNativeBinding: true),
            packageLockData: try packageLockData(),
            nodeArchiveSHA256Override: fixtureSHA256
        )

        _ = try await provisioner.provision()

        let fileManager = FileManager.default
        let module = RuntimeLocator.harnessRoot(
            root: root,
            architecture: architecture,
            harnessVersion: RuntimeRelease.harnessVersion
        )
            .appendingPathComponent("node_modules/fs-ext", isDirectory: true)
        XCTAssertTrue(
            fileManager.fileExists(atPath: module.appendingPathComponent("build/Release/fs_ext.node").path),
            "the binding is compiled during the install"
        )
        // node-gyp's build material carries absolute build paths and must not ship.
        XCTAssertFalse(fileManager.fileExists(atPath: module.appendingPathComponent("build/Release/fs_ext.o").path))
        XCTAssertFalse(fileManager.fileExists(atPath: module.appendingPathComponent("build/Release/fs_ext.d").path))
        XCTAssertFalse(fileManager.fileExists(atPath: module.appendingPathComponent("build/Makefile").path))
        XCTAssertFalse(fileManager.fileExists(atPath: module.appendingPathComponent("build/obj.target").path))
    }

    /// A binding the packaged Node cannot load fails the install instead of shipping.
    func testNativeBindingThatDoesNotLoadFailsTheInstall() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Runtime", isDirectory: true)
        let provisioner = RuntimeProvisioner(
            root: root,
            architecture: architecture,
            downloader: FixtureDownloader(data: Data("node archive fixture".utf8)),
            commandRunner: FixtureCommandRunner(
                includesNativeBinding: true,
                nativeBindingFailsToLoad: true
            ),
            packageLockData: try packageLockData(),
            nodeArchiveSHA256Override: fixtureSHA256
        )

        do {
            _ = try await provisioner.provision()
            XCTFail("expected the module load failure to fail the install")
        } catch let error as RuntimeProvisioningError {
            guard case .runtimeValidationFailed(let detail) = error else {
                return XCTFail("expected a runtime validation failure, got \(error)")
            }
            XCTAssertTrue(detail.contains("fs-ext"), "the failure names the module: \(detail)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    /// A Harness line without the module installs with no extra commands.
    func testHarnessWithoutTheNativeModuleSkipsTheBindingStep() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Runtime", isDirectory: true)
        let commandRunner = FixtureCommandRunner()
        let provisioner = RuntimeProvisioner(
            root: root,
            architecture: architecture,
            downloader: FixtureDownloader(data: Data("node archive fixture".utf8)),
            commandRunner: commandRunner,
            packageLockData: try packageLockData(),
            nodeArchiveSHA256Override: fixtureSHA256
        )

        _ = try await provisioner.provision()

        XCTAssertEqual(commandRunner.invocationCount, 2, "only the extraction and the install ran")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: RuntimeLocator.harnessRoot(
                    root: root,
                    architecture: architecture,
                    harnessVersion: RuntimeRelease.harnessVersion
                )
                    .appendingPathComponent("node_modules/fs-ext").path
            )
        )
    }
}
