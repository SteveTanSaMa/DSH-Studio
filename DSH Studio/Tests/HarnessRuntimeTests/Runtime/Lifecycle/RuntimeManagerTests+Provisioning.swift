import XCTest
@testable import DeepSeekRuntime
@testable import DeepSeekHarness
@testable import DeepSeekLogging

extension RuntimeManagerTests {

    @MainActor
    func testAutomaticProvisioningUpdatesConfigurationBeforeLaunch() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-provisioner-\(UUID().uuidString)", isDirectory: true)
        let provisioner = FakeRuntimeProvisioner(root: root)
        let process = FakeHarnessProcess()
        let manager = makeManager(process: process, provisioner: provisioner)

        manager.start()
        XCTAssertEqual(manager.state, .provisioning)
        let starting = await waitUntil(manager.state == .starting)
        XCTAssertTrue(starting)
        XCTAssertEqual(
            manager.configuration.nodeExecutable,
            RuntimeLocator.nodeExecutable(root: root, architecture: "darwin-arm64")
        )
        XCTAssertEqual(
            manager.configuration.harnessEntry,
            RuntimeLocator.harnessEntry(root: root, architecture: "darwin-arm64")
        )

        process.emitOutput("dsh web: http://127.0.0.1:43220\n")
        let ready = await waitUntil(manager.state == .ready)
        XCTAssertTrue(ready)
    }

    @MainActor
    func testProvisioningFailureIsReportedAndDoesNotLaunchProcess() async {
        let process = FakeHarnessProcess()
        let provisioner = FakeRuntimeProvisioner(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("dsh-provisioner-\(UUID().uuidString)", isDirectory: true),
            error: RuntimeProvisioningError.installationFailed("fixture failure")
        )
        let manager = makeManager(process: process, provisioner: provisioner)

        manager.start()
        let failed = await waitUntil(manager.state == .failed)
        XCTAssertTrue(failed)
        guard case .runtimeProvisioningFailed(let detail) = manager.lastError else {
            return XCTFail("expected a provisioning failure, got \(String(describing: manager.lastError))")
        }
        XCTAssertTrue(detail.contains("fixture failure"))
        XCTAssertEqual(process.launchCount, 0)
    }

    @MainActor
    func testStopDuringProvisioningCancelsProvisioningAndStaysTerminated() async {
        let provisioner = FakeRuntimeProvisioner(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("dsh-provisioner-\(UUID().uuidString)", isDirectory: true),
            waitsForCancellation: true
        )
        let manager = makeManager(provisioner: provisioner)

        manager.start()
        let provisioning = await waitUntil(manager.state == .provisioning)
        XCTAssertTrue(provisioning)
        await manager.stop()
        XCTAssertEqual(manager.state, .terminated)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(manager.state, .terminated)
    }
}
