//
//  WorkspaceAdmissionTests.swift
//  DSH Studio
//

import Foundation
import XCTest

/// Verifies which workspace directories are admitted, and which stored paths survive.
///
/// The workspace becomes the Harness child process's working directory, so a path
/// that is not a usable directory has to be rejected before it reaches a launch.
final class WorkspaceAdmissionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DSHStudio-WorkspaceAdmission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A readable, writable directory is admitted as its standardized URL.
    func testWritableDirectoryIsAdmitted() throws {
        let workspace = try makeDirectory("workspace")
        // Compared by path: the admitted URL keeps the caller's spelling, and the
        // directory flag is not part of what callers consume.
        XCTAssertEqual(
            try WorkspaceAdmission.validateSelectedDirectory(workspace).path,
            workspace.standardizedFileURL.path
        )
    }

    /// A path that does not exist is rejected.
    func testMissingDirectoryIsRejected() {
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        XCTAssertThrowsError(try WorkspaceAdmission.validateSelectedDirectory(missing)) { error in
            XCTAssertEqual(error as? WorkspaceAdmissionError, .notDirectory)
        }
    }

    /// A regular file is rejected even though the path exists.
    func testFileIsRejected() throws {
        let file = root.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: file)
        XCTAssertThrowsError(try WorkspaceAdmission.validateSelectedDirectory(file)) { error in
            XCTAssertEqual(error as? WorkspaceAdmissionError, .notDirectory)
        }
    }

    /// A directory the user cannot write to is rejected.
    func testUnwritableDirectoryIsRejected() throws {
        let locked = try makeDirectory("locked")
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o500)],
            ofItemAtPath: locked.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: locked.path
            )
        }
        XCTAssertThrowsError(try WorkspaceAdmission.validateSelectedDirectory(locked)) { error in
            XCTAssertEqual(error as? WorkspaceAdmissionError, .notWritable)
        }
    }

    /// A stored path that no longer exists is kept while its parent stays writable.
    ///
    /// Runtime creates the default workspace on first launch, so discarding the
    /// stored choice here would silently reset the user's selection.
    func testStoredMissingPathSurvivesWithWritableParent() {
        let planned = root.appendingPathComponent("planned", isDirectory: true)
        // The rebuilt URL carries no directory marker, so only the path is asserted.
        XCTAssertEqual(
            WorkspaceAdmission.persistedURL(from: planned.path)?.path,
            planned.standardizedFileURL.path
        )
    }

    /// A stored path whose parent is gone is discarded.
    func testStoredPathWithMissingParentIsDiscarded() {
        let orphan = root.appendingPathComponent("gone/child", isDirectory: true)
        XCTAssertNil(WorkspaceAdmission.persistedURL(from: orphan.path))
    }

    /// An existing readable directory is kept as stored.
    func testStoredExistingDirectoryIsKept() throws {
        let workspace = try makeDirectory("workspace")
        XCTAssertEqual(
            WorkspaceAdmission.persistedURL(from: workspace.path)?.path,
            workspace.standardizedFileURL.path
        )
    }

    /// Absent and blank stored values are discarded.
    func testBlankAndAbsentStoredValuesAreDiscarded() {
        XCTAssertNil(WorkspaceAdmission.persistedURL(from: nil))
        XCTAssertNil(WorkspaceAdmission.persistedURL(from: "   "))
    }

    // MARK: - Helpers

    /// Creates a directory under the isolated root.
    ///
    /// - Parameter name: Directory name to create.
    /// - Returns: The created directory.
    /// - Throws: When the directory cannot be created.
    private func makeDirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
