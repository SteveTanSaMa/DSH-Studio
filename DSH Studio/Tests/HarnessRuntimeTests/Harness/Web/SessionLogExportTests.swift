//
//  SessionLogExportTests.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import Foundation
import XCTest
@testable import DeepSeekHarness

/// Verifies safe Session ZIP URL creation and atomic file handling.
final class SessionLogExportTests: XCTestCase {
    func testExportURLEncodesSessionIDAndIncludesDescendants() throws {
        let url = try SessionLogExport.exportURL(
            baseURL: URL(string: "http://127.0.0.1:43123")!,
            sessionID: "session id/a&b#c"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/api/session.export")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "sessionId" })?.value, "session id/a&b#c")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "includeDescendants" })?.value, "true")
        XCTAssertTrue(components.percentEncodedQuery?.contains("session%20id/a%26b%23c") == true)
    }

    func testFilenameIsStableAndCannotEscapeTheSaveDirectory() {
        XCTAssertEqual(
            SessionLogExport.filename(sessionID: "session-123"),
            "dsh-session-session-123.zip"
        )
        XCTAssertEqual(
            SessionLogExport.filename(sessionID: "../session/123"),
            "dsh-session-___session_123.zip"
        )
    }

    func testRemoteBaseURLIsRejected() {
        XCTAssertThrowsError(
            try SessionLogExport.exportURL(
                baseURL: URL(string: "http://localhost:43123")!,
                sessionID: "session-123"
            )
        ) { error in
            XCTAssertEqual(error as? SessionLogExportError, .invalidBaseURL)
        }
    }

    func testHTTPFailureReportsStatusAndCleansTemporaryResponse() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let client = SessionLogDownloadClient(
            transport: { _ in
                let responseURL = temporaryDirectory.appendingPathComponent("response")
                try Data("session missing".utf8).write(to: responseURL)
                return SessionLogTemporaryDownload(fileURL: responseURL, statusCode: 404)
            },
            temporaryDirectory: temporaryDirectory
        )

        do {
            _ = try await client.stage(
                sessionID: "missing",
                baseURL: URL(string: "http://127.0.0.1:43123")!
            )
            XCTFail("expected an HTTP error")
        } catch let error as SessionLogExportError {
            XCTAssertEqual(error, .httpStatus(404, "session missing"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path), [])
    }

    func testEmptyAndNonZIPResponsesAreRejected() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let responseURL = temporaryDirectory.appendingPathComponent("response")
        let emptyClient = SessionLogDownloadClient(
            transport: { _ in
                try Data().write(to: responseURL)
                return SessionLogTemporaryDownload(fileURL: responseURL, statusCode: 200)
            },
            temporaryDirectory: temporaryDirectory
        )
        do {
            _ = try await emptyClient.stage(sessionID: "empty", baseURL: URL(string: "http://127.0.0.1:43123")!)
            XCTFail("expected an empty response error")
        } catch let error as SessionLogExportError {
            XCTAssertEqual(error, .emptyResponse)
        }

        let nonZIPClient = SessionLogDownloadClient(
            transport: { _ in
                try Data("not a zip".utf8).write(to: responseURL)
                return SessionLogTemporaryDownload(fileURL: responseURL, statusCode: 200)
            },
            temporaryDirectory: temporaryDirectory
        )

        do {
            _ = try await nonZIPClient.stage(sessionID: "bad", baseURL: URL(string: "http://127.0.0.1:43123")!)
            XCTFail("expected a non-ZIP error")
        } catch let error as SessionLogExportError {
            XCTAssertEqual(error, .notZIP)
        }
    }

    func testZIPStagesAndCommitsWithoutLeavingPartialDestination() async throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        let destinationDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            try? FileManager.default.removeItem(at: destinationDirectory)
        }
        let responseURL = temporaryDirectory.appendingPathComponent("response")
        let zip = Data([0x50, 0x4B, 0x05, 0x06] + Array(repeating: 0, count: 18))
        let client = SessionLogDownloadClient(
            transport: { request in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.query?.contains("includeDescendants=true"), true)
                try zip.write(to: responseURL)
                return SessionLogTemporaryDownload(fileURL: responseURL, statusCode: 200)
            },
            temporaryDirectory: temporaryDirectory
        )
        let staged = try await client.stage(
            sessionID: "session-123",
            baseURL: URL(string: "http://127.0.0.1:43123")!
        )
        let destination = destinationDirectory.appendingPathComponent("dsh-session-session-123.zip")
        try client.commit(stagedURL: staged, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), zip)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        let partials = try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path)
            .filter { $0.contains("partial") }
        XCTAssertTrue(partials.isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
