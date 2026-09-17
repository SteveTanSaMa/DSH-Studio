//
//  HarnessNotificationEvent.swift
//  DSH Studio
//

import Foundation

/// The small subset of the Harness mux stream that can change notification state.
enum HarnessNotificationEvent: Equatable, Sendable {
    /// A turn finished; carries the session, the turn number, and why it ended.
    case turnCompleted(sessionID: String, turn: Int, reason: HarnessTurnEndReason)
    /// Harness is waiting for a permission decision.
    case permissionWaiting(sessionID: String, requestID: String)
    /// A permission decision arrived, so the pending notification is stale.
    case permissionResolved(sessionID: String, requestID: String)
    /// Harness is waiting for an answer before it can continue.
    case questionWaiting(sessionID: String, requestID: String)
    /// A question was answered, so the pending notification is stale.
    case questionResolved(sessionID: String, requestID: String)

    /// Decodes one mux frame into a notification event.
    ///
    /// Only the frame types that can change notification state are recognized; every
    /// other frame, including tool activity, returns `nil`.
    ///
    /// - Parameter data: Raw frame received from the Harness event stream.
    /// - Returns: The decoded event, or `nil` when the frame is unrelated or malformed.
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

/// Why a turn ended, as reported by Harness.
enum HarnessTurnEndReason: Equatable, Sendable {
    /// The turn finished normally.
    case completed
    /// The turn stopped because it needs the user.
    case blocked
    /// The turn ended with an error.
    case error
    /// The turn was aborted.
    case aborted
    /// The turn hit its token limit.
    case maxTokens
    /// The turn was interrupted.
    case interrupted
    /// A reason this build does not know; carries the raw kind.
    case other(String)

    /// Maps a wire reason onto a known case.
    ///
    /// - Parameter kind: Reason string from the turn-end payload.
    /// - Returns: Never `nil`: an unknown reason becomes ``other(_:)``.
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

/// A notification the app decided to deliver.
///
/// This is the deduper's output, after the focus policy and the per-kind
/// preferences have been applied.
enum AppNotificationKind: Equatable, Sendable {
    /// A turn completed; carries why it ended.
    case turnCompleted(reason: HarnessTurnEndReason)
    /// Harness needs a permission decision.
    case permissionWaiting
    /// Harness needs an answer to continue.
    case questionWaiting
}

/// Deduplicates replayed stream frames and applies the app's focus policy.
struct NotificationEventDeduper: Sendable {
    private var completedTurns = Set<String>()
    private var pendingPermissions = Set<String>()
    private var pendingQuestions = Set<String>()

    /// Decides whether an event should notify, applying preferences and dedup.
    ///
    /// Each turn or request notifies at most once: replaying the same frame returns
    /// `nil`, and a resolved request frees its key so a later one can notify again.
    ///
    /// - Parameters:
    ///   - event: Event decoded from the stream.
    ///   - completionPreference: When completed turns should notify.
    ///   - appIsActive: Whether the app is frontmost right now.
    ///   - permissionNotificationsEnabled: Whether permission prompts notify.
    ///   - questionNotificationsEnabled: Whether question prompts notify.
    /// - Returns: The notification to deliver, or `nil` to stay silent.
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

    /// Forgets every delivered and pending key, so a replayed stream notifies again.
    mutating func reset() {
        completedTurns.removeAll()
        pendingPermissions.removeAll()
        pendingQuestions.removeAll()
    }
}
