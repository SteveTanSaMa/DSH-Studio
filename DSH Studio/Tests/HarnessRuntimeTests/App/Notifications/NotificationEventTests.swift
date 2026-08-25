//
//  NotificationEventTests.swift
//  DSH Studio
//

import Foundation
import UserNotifications
import XCTest

final class NotificationEventTests: XCTestCase {
    func testWebSocketFrameAndTurnEnd() throws {
        let json = #"""
        {
          "type": "server-request",
          "rpcId": "frame-1",
          "payload": {
            "type": "session/event",
            "sessionId": "session-1",
            "event": {
              "type": "turn/end",
              "data": { "turn": 7, "reason": { "kind": "completed" } }
            }
          }
        }
        """#

        XCTAssertEqual(
            HarnessNotificationEvent(wireData: Data(json.utf8)),
            .turnCompleted(sessionID: "session-1", turn: 7, reason: .completed)
        )
    }

    func testTurnEndReasonIsPreservedForNonSuccessfulResults() {
        let event = HarnessNotificationEvent(wireData: Data(#"""
        {"payload":{"type":"session/event","sessionId":"s","event":{"type":"turn/end","data":{"turn":2,"reason":{"kind":"error"}}}}}
        """#.utf8))

        XCTAssertEqual(
            event,
            .turnCompleted(sessionID: "s", turn: 2, reason: .error)
        )
    }

    func testToolEventsDoNotBecomeNotificationEvents() {
        let toolCall = HarnessNotificationEvent(wireData: Data(#"""
        {"rpcId":"frame-tool","payload":{"type":"session/event","sessionId":"s","event":{"type":"tool/call","data":{"turn":1,"step":1,"callId":"c","name":"shell","arguments":"{}"}}}}
        """#.utf8))
        XCTAssertNil(toolCall)
    }

    func testMuxInteractionFramesUseStableRequestIdentifiers() {
        let approval = HarnessNotificationEvent(wireData: Data(#"""
        {"rpcId":"frame-2","payload":{"type":"approval/requested","sessionId":"s","approvalId":"a"}}
        """#.utf8))
        XCTAssertEqual(
            approval,
            .permissionWaiting(sessionID: "s", requestID: "a")
        )

        let question = HarnessNotificationEvent(wireData: Data(#"""
        {"rpcId":"q-1","payload":{"type":"question/requested","sessionId":"s","questions":[{"id":"q"}]}}
        """#.utf8))
        XCTAssertEqual(
            question,
            .questionWaiting(sessionID: "s", requestID: "q-1")
        )

        let resolved = HarnessNotificationEvent(wireData: Data(#"""
        {"rpcId":"frame-3","payload":{"type":"question/resolved","sessionId":"s","questionRpcId":"q-1","outcome":"answered"}}
        """#.utf8))
        XCTAssertEqual(
            resolved,
            .questionResolved(sessionID: "s", requestID: "q-1")
        )
    }

    func testDeduperAppliesFocusPolicyAndSuppressesReplays() {
        var deduper = NotificationEventDeduper()
        let turn = HarnessNotificationEvent.turnCompleted(sessionID: "s", turn: 1, reason: .completed)

        XCTAssertNil(deduper.consume(
            turn,
            completionPreference: .whenNotFocused,
            appIsActive: true,
            permissionNotificationsEnabled: true,
            questionNotificationsEnabled: true
        ))
        XCTAssertNil(deduper.consume(
            turn,
            completionPreference: .whenNotFocused,
            appIsActive: false,
            permissionNotificationsEnabled: true,
            questionNotificationsEnabled: true
        ))

        deduper.reset()
        XCTAssertEqual(deduper.consume(
            turn,
            completionPreference: .always,
            appIsActive: true,
            permissionNotificationsEnabled: true,
            questionNotificationsEnabled: true
        ), .turnCompleted(reason: .completed))
        XCTAssertNil(deduper.consume(
            turn,
            completionPreference: .always,
            appIsActive: true,
            permissionNotificationsEnabled: true,
            questionNotificationsEnabled: true
        ))
    }

    func testPendingInteractionsNotifyOnceUntilResolved() {
        var deduper = NotificationEventDeduper()
        let permission = HarnessNotificationEvent.permissionWaiting(sessionID: "s", requestID: "p")
        let permissionResolved = HarnessNotificationEvent.permissionResolved(sessionID: "s", requestID: "p")

        XCTAssertEqual(deduper.consume(
            permission,
            completionPreference: .never,
            appIsActive: true,
            permissionNotificationsEnabled: true,
            questionNotificationsEnabled: true
        ), .permissionWaiting)
        XCTAssertNil(deduper.consume(
            permission,
            completionPreference: .never,
            appIsActive: true,
            permissionNotificationsEnabled: true,
            questionNotificationsEnabled: true
        ))
        XCTAssertNil(deduper.consume(
            permissionResolved,
            completionPreference: .never,
            appIsActive: true,
            permissionNotificationsEnabled: true,
            questionNotificationsEnabled: true
        ))
        XCTAssertEqual(deduper.consume(
            permission,
            completionPreference: .never,
            appIsActive: true,
            permissionNotificationsEnabled: true,
            questionNotificationsEnabled: true
        ), .permissionWaiting)
    }

    @MainActor
    func testCoordinatorRequestsAuthorizationOnlyForARealNotification() async {
        let suiteName = "DeepSeekStudio.NotificationTests.coordinator.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        let center = RecordingNotificationCenter(status: .notDetermined, grant: true)
        let coordinator = AppNotificationCoordinator(
            settings: settings,
            notificationCenter: center,
            isAppActive: { false }
        )

        coordinator.handle(.turnCompleted(sessionID: "s", turn: 1, reason: .completed))
        await waitForNotificationWork(center, expectedAddedRequests: 1)

        XCTAssertEqual(center.authorizationRequests, 1)
        XCTAssertEqual(center.addedRequests, 1)
        let body = center.requests[0].content.body
        XCTAssertEqual(body, "DSH Studio has completed a trun.")

        coordinator.handle(.permissionWaiting(sessionID: "s", requestID: "p"))
        await waitForNotificationWork(center, expectedAddedRequests: 2)
        XCTAssertTrue(center.requests[1].content.body.contains("DSH Studio"))
    }

    @MainActor
    func testDisabledTurnNotificationsDoNotRequestAuthorization() async {
        let suiteName = "DeepSeekStudio.NotificationTests.disabled.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        settings.turnCompletionNotification = .never
        let center = RecordingNotificationCenter(status: .notDetermined, grant: true)
        let coordinator = AppNotificationCoordinator(
            settings: settings,
            notificationCenter: center,
            isAppActive: { false }
        )

        coordinator.handle(.turnCompleted(sessionID: "s", turn: 1, reason: .completed))
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(center.authorizationRequests, 0)
        XCTAssertEqual(center.addedRequests, 0)
    }

    @MainActor
    func testCoordinatorDoesNotLetDeniedAuthorizationAffectLaterEvents() async {
        let suiteName = "DeepSeekStudio.NotificationTests.denied.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults)
        let center = RecordingNotificationCenter(status: .notDetermined, grant: false)
        let coordinator = AppNotificationCoordinator(
            settings: settings,
            notificationCenter: center,
            isAppActive: { false }
        )

        coordinator.handle(.turnCompleted(sessionID: "s", turn: 1, reason: .completed))
        await waitForNotificationWork(center, expectedAddedRequests: 0)
        coordinator.handle(.turnCompleted(sessionID: "s", turn: 2, reason: .completed))
        await Task.yield()

        XCTAssertEqual(center.authorizationRequests, 1)
        XCTAssertEqual(center.addedRequests, 0)
    }

    @MainActor
    private func waitForNotificationWork(
        _ center: RecordingNotificationCenter,
        expectedAddedRequests: Int
    ) async {
        for _ in 0..<50 {
            if center.authorizationRequests > 0 && center.addedRequests >= expectedAddedRequests {
                return
            }
            await Task.yield()
        }
    }
}

private final class RecordingNotificationCenter: AppNotificationCenterClient {
    let status: UNAuthorizationStatus
    let grant: Bool
    private(set) var authorizationRequests = 0
    private(set) var requests: [UNNotificationRequest] = []

    var addedRequests: Int {
        requests.count
    }

    init(status: UNAuthorizationStatus, grant: Bool) {
        self.status = status
        self.grant = grant
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        status
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authorizationRequests += 1
        return grant
    }

    func add(_ request: UNNotificationRequest) async throws {
        requests.append(request)
    }
}
