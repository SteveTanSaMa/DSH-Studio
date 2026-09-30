import XCTest
@testable import DeepSeekRuntime
@testable import DeepSeekHarness
@testable import DeepSeekLogging

/// Provisioning cases: installing before launch, and cancelling mid-install.
extension RuntimeManagerTests {

    /// Automatic provisioning updates the configuration before the launch.
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

    /// A provisioning failure is reported and no process is launched.
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

    /// Stopping during provisioning cancels it and leaves the Runtime terminated.
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

    /// Installation progress reaches the log and is cleared once the Runtime is up.
    ///
    /// A first launch downloads close to 200 MiB, so the milestones are what explains
    /// afterwards how long it took.
    @MainActor
    func testProvisioningReportsMilestonesToTheLogAndClearsThemAtTheEnd() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-provisioner-\(UUID().uuidString)", isDirectory: true)
        let provisioner = FakeRuntimeProvisioner(root: root)
        provisioner.reportedProgress = [
            RuntimeProvisioningProgress(fraction: 0, detail: "正在下载 Runtime（188 MB）…"),
            RuntimeProvisioningProgress(fraction: 0.4, detail: "正在下载 Runtime（188 MB）…"),
            RuntimeProvisioningProgress(fraction: nil, detail: "正在校验并解包 Runtime…"),
        ]
        let process = FakeHarnessProcess()
        let manager = makeManager(process: process, provisioner: provisioner)

        manager.start()
        let starting = await waitUntil(manager.state == .starting)
        XCTAssertTrue(starting)
        process.emitOutput("dsh web: http://127.0.0.1:43221\n")
        let ready = await waitUntil(manager.state == .ready)

        XCTAssertTrue(ready)
        XCTAssertNil(manager.provisioningProgress, "the loading surface stops reporting once Harness is up")
        let messages = manager.logs.entries.map(\.message)
        XCTAssertTrue(
            messages.contains { $0.contains("正在下载 Runtime（188 MB）… 0%") },
            "the download is logged: \(messages)"
        )
        XCTAssertTrue(
            messages.contains { $0.contains("正在下载 Runtime（188 MB）… 40%") },
            "progress milestones are logged: \(messages)"
        )
        XCTAssertTrue(messages.contains { $0.contains("正在校验并解包 Runtime…") })
    }

    /// The host's pre-launch work runs after provisioning and before the launch.
    ///
    /// The profile Harness boots from is written there, so running it any later would be
    /// too late for the process to load what it holds.
    @MainActor
    func testPrelaunchPreparationRunsBeforeTheProcessStarts() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-provisioner-\(UUID().uuidString)", isDirectory: true)
        let provisioner = FakeRuntimeProvisioner(root: root)
        let process = FakeHarnessProcess()
        let manager = makeManager(process: process, provisioner: provisioner)
        var preparedWithProcessCount: Int?
        manager.prelaunchPreparation = {
            preparedWithProcessCount = process.launchCount
        }

        manager.start()
        let starting = await waitUntil(manager.state == .starting)
        XCTAssertTrue(starting)
        process.emitOutput("dsh web: http://127.0.0.1:43222\n")
        let ready = await waitUntil(manager.state == .ready)

        XCTAssertTrue(ready)
        XCTAssertEqual(preparedWithProcessCount, 0, "the preparation ran before the process was launched")
        XCTAssertEqual(process.launchCount, 1)
    }
}
