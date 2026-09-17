import Foundation
import XCTest

@testable import DeepSeekRuntime

/// Guards data-profile identity, isolation, and activation state.
final class RuntimeDataProfileTests: XCTestCase {
    /// Isolated root each test creates its profiles under.
    var temporaryRoot: URL!

    /// Creates the isolated root directory.
    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepSeekStudio.RuntimeDataProfileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    /// Removes the isolated root.
    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }
}
