import Foundation
import XCTest
@testable import DeepSeekRuntime

/// Guards the command runner's output capture.
final class RuntimeCommandRunnerTests: XCTestCase {
    /// Large output is captured without the child blocking on a full pipe.
    func testCapturesLargeStdoutAndStderrWithoutPipeBackpressure() throws {
        let result = try SystemRuntimeCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "printf '%*s' 200000 '' | tr ' ' 'o'; printf '%*s' 200000 '' | tr ' ' 'e' >&2",
            ],
            currentDirectory: FileManager.default.temporaryDirectory,
            environment: ProcessInfo.processInfo.environment
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.count, 200_000)
        XCTAssertEqual(result.stderr.count, 100_000)
        XCTAssertTrue(result.stdout.allSatisfy { $0 == "o" })
        XCTAssertTrue(result.stderr.allSatisfy { $0 == "e" })
    }
}
