import Foundation
import XCTest
@testable import DeepSeekHarness
@testable import DeepSeekRuntime

final class PluginMarketHTTPClientTests: XCTestCase {
    func testRoutesUseTheAllowedLoopbackEndpoint() async throws {
        let transport = RecordingPluginMarketTransport { request in
            XCTAssertEqual(request.url?.path, "/dsh-market/status")
            return PluginMarketHTTPResponse(
                statusCode: 200,
                data: Data("{\"active\":true,\"version\":\"1.21.2\"}".utf8)
            )
        }
        let client = PluginMarketHTTPClient(transport: transport)
        let status = try await client.status(baseURL: URL(string: "http://127.0.0.1:43123/")!)

        XCTAssertEqual(status.active, true)
        XCTAssertEqual(status.version, "1.21.2")
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testNonLoopbackAndMalformedResponsesFailClosed() async {
        let transport = RecordingPluginMarketTransport { _ in
            PluginMarketHTTPResponse(statusCode: 200, data: Data("not-json".utf8))
        }
        let client = PluginMarketHTTPClient(transport: transport)

        do {
            _ = try await client.status(baseURL: URL(string: "http://localhost:43123/")!)
            XCTFail("localhost must be rejected")
        } catch PluginMarketHTTPError.invalidBaseURL {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        do {
            _ = try await client.status(baseURL: URL(string: "http://127.0.0.1:43123/")!)
            XCTFail("invalid JSON must be rejected")
        } catch PluginMarketHTTPError.invalidResponse {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCheckAndLogsPreserveRawDiagnosticPayloads() async throws {
        let transport = RecordingPluginMarketTransport { request in
            switch request.url?.path {
            case "/dsh-market/check":
                return PluginMarketHTTPResponse(statusCode: 200, data: Data("{\"ok\":true}".utf8))
            case "/dsh-market/logs":
                return PluginMarketHTTPResponse(statusCode: 200, data: Data("line one\nline two".utf8))
            default:
                return PluginMarketHTTPResponse(statusCode: 404, data: Data())
            }
        }
        let client = PluginMarketHTTPClient(transport: transport)
        let baseURL = URL(string: "http://127.0.0.1:43123/")!

        let checkData = try await client.check(baseURL: baseURL)
        let logs = try await client.logs(baseURL: baseURL)
        XCTAssertEqual(String(decoding: checkData, as: UTF8.self), "{\"ok\":true}")
        XCTAssertEqual(logs, "line one\nline two")
    }
}

private final class RecordingPluginMarketTransport: PluginMarketHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    private let handler: (URLRequest) -> PluginMarketHTTPResponse

    init(handler: @escaping (URLRequest) -> PluginMarketHTTPResponse) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> PluginMarketHTTPResponse {
        record(request)
        return handler(request)
    }

    private func record(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }
}
