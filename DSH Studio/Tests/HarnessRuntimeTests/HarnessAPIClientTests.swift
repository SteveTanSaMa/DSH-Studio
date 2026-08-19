//
//  HarnessAPIClientTests.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import Foundation
import XCTest
@testable import DeepSeekHarness

/// Verifies RPC envelopes, revisions, remote errors, and URL rejection.
final class HarnessAPIClientTests: XCTestCase {
    func testSettingsDescribeUsesOfficialEnvelopeAndPreservesBoundaries() async throws {
        let transport = RecordingHarnessTransport { request in
            let requestObject = try XCTUnwrap(Self.jsonObject(from: request))
            let rpcID = try XCTUnwrap(requestObject["rpcId"] as? String)
            let body = """
            {
              "type": "server-response",
              "rpcId": "\(rpcID)",
              "result": {
                "ok": true,
                "value": {
                  "writable": true,
                  "hasDocument": true,
                  "namespaces": [{
                    "ns": "llm-deepseek",
                    "schema": {"type": "object"},
                    "value": {"baseURL": "https://api.deepseek.com", "enabled": true, "temperature": 0.7, "tools": ["search", null]},
                    "base": {"enabled": true},
                    "user": {"baseURL": "https://override"},
                    "applies": "restart",
                    "secrets": [{"path": ["apiKey"], "set": true}],
                    "revision": 7
                  }]
                }
              }
            }
            """
            return HarnessHTTPResponse(statusCode: 200, data: Data(body.utf8))
        }

        let snapshot = try await HarnessAPIClient(
            baseURL: URL(string: "http://127.0.0.1:43210")!,
            transport: transport
        ).settingsDescribe()

        XCTAssertEqual(transport.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(transport.lastRequest?.url?.path, "/api/settings.describe")
        XCTAssertEqual(transport.lastRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(snapshot.namespaces.first?.revision, 7)
        XCTAssertEqual(snapshot.namespaces.first?.user?.objectValue?["baseURL"], .string("https://override"))
        XCTAssertEqual(snapshot.namespaces.first?.value.objectValue?["temperature"], .number(0.7))
        XCTAssertEqual(
            snapshot.namespaces.first?.value.objectValue?["tools"],
            .array([.string("search"), .null])
        )
        XCTAssertEqual(snapshot.namespaces.first?.secrets.first?.isSet, true)
    }

    func testSettingsMutateSendsExpectedRevisionAndPathOperations() async throws {
        let transport = RecordingHarnessTransport { request in
            let requestObject = try XCTUnwrap(Self.jsonObject(from: request))
            let rpcID = try XCTUnwrap(requestObject["rpcId"] as? String)
            let body = """
            {"type":"server-response","rpcId":"\(rpcID)","result":{"ok":true,"value":{
              "ns":"ui-theme","schema":{},"value":{"theme":"dark"},"user":{"theme":"dark"},
              "applies":"live","secrets":[],"revision":8
            }}}
            """
            return HarnessHTTPResponse(statusCode: 200, data: Data(body.utf8))
        }
        let client = HarnessAPIClient(
            baseURL: URL(string: "http://127.0.0.1:43210")!,
            transport: transport
        )

        _ = try await client.settingsMutate(
            namespace: "ui-theme",
            operations: [
                .set(path: ["theme"], value: .string("dark")),
                .unset(path: ["fontSize"])
            ],
            expectedRevision: 7
        )

        let requestObject = try XCTUnwrap(Self.jsonObject(from: try XCTUnwrap(transport.lastRequest)))
        XCTAssertEqual(requestObject["method"] as? String, "settings.mutate")
        let payload = try XCTUnwrap(requestObject["payload"] as? [String: Any])
        XCTAssertEqual(payload["ns"] as? String, "ui-theme")
        XCTAssertEqual(payload["expectedRevision"] as? NSNumber, 7)
        let operations = try XCTUnwrap(payload["ops"] as? [[String: Any]])
        XCTAssertEqual(operations.count, 2)
        XCTAssertEqual(operations[0]["op"] as? String, "set")
        XCTAssertEqual(operations[1]["op"] as? String, "unset")
        XCTAssertNil(operations[1]["value"])
    }

    func testSettingsRemoteErrorIsReportedWithoutPretendingToSave() async throws {
        let transport = RecordingHarnessTransport { request in
            let requestObject = try XCTUnwrap(Self.jsonObject(from: request))
            let rpcID = try XCTUnwrap(requestObject["rpcId"] as? String)
            let body = """
            {"type":"server-response","rpcId":"\(rpcID)","result":{"ok":false,
              "error":{"code":"settings-conflict","message":"revision changed","details":{"ns":"ui-theme"}}}}
            """
            return HarnessHTTPResponse(statusCode: 200, data: Data(body.utf8))
        }

        do {
            _ = try await HarnessAPIClient(
                baseURL: URL(string: "http://127.0.0.1:43210")!,
                transport: transport
            ).settingsMutate(namespace: "ui-theme", operations: [], expectedRevision: 7)
            XCTFail("expected the remote error")
        } catch let error as HarnessAPIError {
            XCTAssertEqual(error, .remote(code: "settings-conflict", message: "revision changed"))
        }
    }

    func testRemoteBaseURLIsRejectedBeforeTransport() async throws {
        let transport = RecordingHarnessTransport { _ in
            XCTFail("remote URL should be rejected before transport")
            return HarnessHTTPResponse(statusCode: 200, data: Data())
        }

        do {
            _ = try await HarnessAPIClient(
                baseURL: URL(string: "http://0.0.0.0:43210")!,
                transport: transport
            ).settingsDescribe()
            XCTFail("expected an invalid base URL")
        } catch let error as HarnessAPIError {
            XCTAssertEqual(error, .invalidBaseURL)
        }
    }

    private static func jsonObject(from request: URLRequest) -> [String: Any]? {
        guard let body = request.httpBody else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

private final class RecordingHarnessTransport: HarnessAPITransport, @unchecked Sendable {
    let handler: (URLRequest) throws -> HarnessHTTPResponse
    private(set) var lastRequest: URLRequest?

    init(handler: @escaping (URLRequest) throws -> HarnessHTTPResponse) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> HarnessHTTPResponse {
        lastRequest = request
        return try handler(request)
    }
}
