import XCTest
@testable import DeepSeekRuntime
@testable import DeepSeekHarness
@testable import DeepSeekLogging

extension RuntimeManagerTests {

    @MainActor
    func testGracefulStop() async {
        let fake = FakeHarnessProcess()
        let manager = makeManager(process: fake, healthResult: true)
        manager.start()
        fake.emitOutput("dsh web: http://127.0.0.1:43213\n")
        _ = await waitUntil(manager.state == .ready)
        await manager.stop()
        XCTAssertEqual(manager.state, .terminated)
        XCTAssertEqual(fake.forceCount, 0)
    }

    @MainActor
    func testStopAfterRestartStopsTheCurrentProcess() async {
        let fake = FakeHarnessProcess()
        let manager = makeManager(process: fake, healthResult: true, gracefulTimeout: 0.01)

        manager.start()
        fake.emitOutput("dsh web: http://127.0.0.1:43216\n")
        _ = await waitUntil(manager.state == .ready)
        await manager.stop()

        manager.start()
        fake.emitOutput("dsh web: http://127.0.0.1:43217\n")
        _ = await waitUntil(manager.state == .ready)
        await manager.stop()

        XCTAssertEqual(manager.state, .terminated)
        XCTAssertEqual(fake.gracefulCount, 2)
    }

    @MainActor
    func testForcedStop() async {
        let fake = FakeHarnessProcess()
        fake.ignoreGracefulTermination = true
        let manager = makeManager(process: fake, gracefulTimeout: 0.05)
        manager.start()
        await manager.stop()
        XCTAssertEqual(manager.state, .terminated)
        XCTAssertEqual(fake.forceCount, 1)
    }

    @MainActor
    func testRepeatedStopCallsCoalesce() async {
        let fake = FakeHarnessProcess()
        fake.ignoreGracefulTermination = true
        let manager = makeManager(process: fake, gracefulTimeout: 0.05)
        manager.start()
        async let first = manager.stop()
        async let second = manager.stop()
        _ = await (first, second)
        XCTAssertEqual(fake.forceCount, 1)
    }
}
