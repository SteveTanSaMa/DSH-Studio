import XCTest
@testable import DeepSeekRuntime
@testable import DeepSeekHarness
@testable import DeepSeekLogging

/// Shutdown cases: graceful, forced, and coalesced stops.
extension RuntimeManagerTests {

    /// A stop returns as soon as the Runtime is gone, not when the budget runs out.
    ///
    /// The graceful budget is a deadline for a Runtime that will not leave; waiting it out
    /// unconditionally made every quit take the full ten seconds even though Harness exits
    /// in milliseconds.
    @MainActor
    func testStopReturnsWhenTheProcessExitsBeforeTheGracefulBudget() async {
        let fake = FakeHarnessProcess()
        let manager = makeManager(process: fake, gracefulTimeout: 3)
        manager.start()
        _ = await waitUntil(fake.launchCount == 1)

        let started = Date()
        await manager.stop()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(manager.state, .terminated)
        XCTAssertLessThan(elapsed, 1, "a Runtime that exits immediately must not cost the budget")
        XCTAssertEqual(fake.forceCount, 0, "nothing had to be killed")
    }

    /// A Runtime that refuses to leave is still killed when the budget expires.
    @MainActor
    func testAStubbornProcessIsKilledWhenTheGracefulBudgetExpires() async {
        let fake = FakeHarnessProcess()
        fake.ignoreGracefulTermination = true
        let manager = makeManager(process: fake, gracefulTimeout: 0.3)
        manager.start()
        _ = await waitUntil(fake.launchCount == 1)

        let started = Date()
        await manager.stop()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(manager.state, .terminated)
        XCTAssertEqual(fake.forceCount, 1, "the deadline still forces the Runtime out")
        XCTAssertGreaterThan(elapsed, 0.25, "the budget is allowed to elapse first")
    }

    /// A graceful stop terminates the child and reports the terminated state.
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

    /// Stopping after a restart stops the new process, not the old one.
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

    /// A forced stop kills the child without waiting for a graceful exit.
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

    /// Concurrent stop calls share one shutdown instead of racing.
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
