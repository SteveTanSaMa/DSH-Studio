//
//  HarnessNotificationEvent.swift
//  DSH Studio
//

import Foundation

/// The small subset of the Harness mux stream that can change notification state.
enum HarnessNotificationEvent: Equatable, Sendable {
    case turnCompleted(sessionID: String, turn: Int, reason: HarnessTurnEndReason)
    case permissionWaiting(sessionID: String, requestID: String)
    case permissionResolved(sessionID: String, requestID: String)
    case questionWaiting(sessionID: String, requestID: String)
    case questionResolved(sessionID: String, requestID: String)

    init?(wireData data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["payload"] as? [String: Any],
              let type = payload["type"] as? String else {
            return nil
        }

        switch type {
        case "session/event":
            guard let sessionID = payload["sessionId"] as? String,
                  let event = payload["event"] as? [String: Any],
                  event["type"] as? String == "turn/end",
                  let eventData = event["data"] as? [String: Any],
                  let turn = (eventData["turn"] as? NSNumber)?.intValue,
                  let reason = eventData["reason"] as? [String: Any],
                  let reasonKind = reason["kind"] as? String else {
                return nil
            }
            self = .turnCompleted(
                sessionID: sessionID,
                turn: turn,
                reason: HarnessTurnEndReason(kind: reasonKind)
            )

        case "approval/requested":
            guard let sessionID = payload["sessionId"] as? String,
                  let requestID = payload["approvalId"] as? String else {
                return nil
            }
            self = .permissionWaiting(sessionID: sessionID, requestID: requestID)

        case "approval/resolved":
            guard let sessionID = payload["sessionId"] as? String,
                  let requestID = payload["approvalId"] as? String else {
                return nil
            }
            self = .permissionResolved(sessionID: sessionID, requestID: requestID)

        case "question/requested":
            guard let sessionID = payload["sessionId"] as? String,
                  let requestID = root["rpcId"] as? String,
                  let questions = payload["questions"] as? [Any],
                  !questions.isEmpty else {
                return nil
            }
            self = .questionWaiting(sessionID: sessionID, requestID: requestID)

        case "question/resolved":
            guard let sessionID = payload["sessionId"] as? String,
                  let requestID = payload["questionRpcId"] as? String else {
                return nil
            }
            self = .questionResolved(sessionID: sessionID, requestID: requestID)

        default:
            return nil
        }
    }
}

enum HarnessTurnEndReason: Equatable, Sendable {
    case completed
    case blocked
    case error
    case aborted
    case maxTokens
    case interrupted
    case other(String)

    init(kind: String) {
        switch kind {
        case "completed": self = .completed
        case "blocked": self = .blocked
        case "error": self = .error
        case "aborted": self = .aborted
        case "max-tokens": self = .maxTokens
        case "interrupted": self = .interrupted
        default: self = .other(kind)
        }
    }
}

enum AppNotificationKind: Equatable, Sendable {
    case turnCompleted(reason: HarnessTurnEndReason)
    case permissionWaiting
    case questionWaiting
}

/// Deduplicates replayed stream frames and applies the app's focus policy.
struct NotificationEventDeduper: Sendable {
    private var completedTurns = Set<String>()
    private var pendingPermissions = Set<String>()
    private var pendingQuestions = Set<String>()

    mutating func consume(
        _ event: HarnessNotificationEvent,
        completionPreference: TurnCompletionNotificationPreference,
        appIsActive: Bool,
        permissionNotificationsEnabled: Bool,
        questionNotificationsEnabled: Bool
    ) -> AppNotificationKind? {
        switch event {
        case let .turnCompleted(sessionID, turn, reason):
            let key = "\(sessionID):\(turn)"
            guard completedTurns.insert(key).inserted else { return nil }
            guard completionPreference != .never else { return nil }
            if completionPreference == .whenNotFocused && appIsActive { return nil }
            return .turnCompleted(reason: reason)

        case let .permissionWaiting(sessionID, requestID):
            let key = "\(sessionID):\(requestID)"
            guard pendingPermissions.insert(key).inserted else { return nil }
            return permissionNotificationsEnabled ? .permissionWaiting : nil

        case let .permissionResolved(sessionID, requestID):
            pendingPermissions.remove("\(sessionID):\(requestID)")
            return nil

        case let .questionWaiting(sessionID, requestID):
            let key = "\(sessionID):\(requestID)"
            guard pendingQuestions.insert(key).inserted else { return nil }
            return questionNotificationsEnabled ? .questionWaiting : nil

        case let .questionResolved(sessionID, requestID):
            pendingQuestions.remove("\(sessionID):\(requestID)")
            return nil
        }
    }

    mutating func reset() {
        completedTurns.removeAll()
        pendingPermissions.removeAll()
        pendingQuestions.removeAll()
    }
}
