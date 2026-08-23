//
//  AppNotificationCoordinator.swift
//  DSH Studio
//

import AppKit
import Foundation
import OSLog
import UserNotifications

protocol AppNotificationCenterClient: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

final class SystemAppNotificationCenter: AppNotificationCenterClient {
    private let center = UNUserNotificationCenter.current()

    func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: options) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

/// Coordinates native notifications without making them a Runtime dependency.
@MainActor
final class AppNotificationCoordinator {
    private let logger = Logger(subsystem: "SteveTan.DSH-Studio", category: "Notifications")
    private let settings: SettingsStore
    private let notificationCenter: any AppNotificationCenterClient
    private let isAppActive: () -> Bool
    private let eventStream: HarnessEventStream
    private var deduper = NotificationEventDeduper()
    private var authorizationState: AuthorizationState = .unknown
    private var pendingNotifications: [AppNotificationKind] = []
    private var runtimeURL: URL?

    init(
        settings: SettingsStore,
        notificationCenter: any AppNotificationCenterClient = SystemAppNotificationCenter(),
        isAppActive: @escaping @MainActor () -> Bool = { NSApp.isActive }
    ) {
        self.settings = settings
        self.notificationCenter = notificationCenter
        self.isAppActive = isAppActive
        eventStream = HarnessEventStream()
        eventStream.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    func updateRuntimeURL(_ url: URL?) {
        guard url != runtimeURL else { return }
        runtimeURL = url
        deduper.reset()
        if let url {
            eventStream.start(baseURL: url)
        } else {
            eventStream.stop()
        }
    }

    func stop() {
        runtimeURL = nil
        eventStream.stop()
        pendingNotifications.removeAll()
    }

    func handle(_ event: HarnessNotificationEvent) {
        guard let kind = deduper.consume(
            event,
            completionPreference: settings.turnCompletionNotification,
            appIsActive: isAppActive(),
            permissionNotificationsEnabled: settings.permissionNotificationsEnabled,
            questionNotificationsEnabled: settings.questionNotificationsEnabled
        ) else {
            return
        }
        deliver(kind)
    }

    private func deliver(_ kind: AppNotificationKind) {
        pendingNotifications.append(kind)
        guard authorizationState == .unknown else {
            if authorizationState == .allowed {
                flushPendingNotifications()
            }
            return
        }

        authorizationState = .checking
        Task { @MainActor [weak self] in
            guard let self else { return }
            let status = await notificationCenter.authorizationStatus()
            self.logger.debug("Notification authorization status: \(String(describing: status), privacy: .public)")
            let granted: Bool
            switch status {
            case .authorized, .provisional, .ephemeral:
                granted = true
            case .denied:
                granted = false
            case .notDetermined:
                self.logger.info("Requesting notification authorization")
                granted = (try? await notificationCenter.requestAuthorization(options: [.alert, .sound])) == true
            @unknown default:
                granted = false
            }
            authorizationState = granted ? .allowed : .denied
            self.logger.info("Notification authorization granted: \(String(granted), privacy: .public)")
            if granted {
                flushPendingNotifications()
            } else {
                pendingNotifications.removeAll()
            }
        }
    }

    private func flushPendingNotifications() {
        let notifications = pendingNotifications
        pendingNotifications.removeAll()
        for kind in notifications {
            let content = UNMutableNotificationContent()
            content.title = localizedTitle(for: kind)
            content.body = localizedBody(for: kind)
            content.sound = .default
            content.threadIdentifier = "dsh-studio"
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            Task { @MainActor [notificationCenter, logger] in
                do {
                    try await notificationCenter.add(request)
                } catch {
                    logger.error("Failed to submit notification: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func localizedTitle(for kind: AppNotificationKind) -> String {
        if Locale.current.identifier.lowercased().hasPrefix("zh") {
            switch kind {
            case let .turnCompleted(reason):
                return reason == .completed ? "轮次已完成" : "轮次已结束"
            case .permissionWaiting: return "需要权限"
            case .questionWaiting: return "需要输入"
            }
        }
        switch kind {
        case let .turnCompleted(reason):
            return reason == .completed ? "Turn completed" : "Turn ended"
        case .permissionWaiting: return "Permission required"
        case .questionWaiting: return "Input required"
        }
    }

    private func localizedBody(for kind: AppNotificationKind) -> String {
        if Locale.current.identifier.lowercased().hasPrefix("zh") {
            switch kind {
            case let .turnCompleted(reason):
                switch reason {
                case .completed:
                    return "DeepSeek Harness 已在 DSH Studio 完成一轮工作。"
                case .blocked:
                    return "DeepSeek Harness 在 DSH Studio 的一轮工作已结束，但当前被阻塞。"
                case .error:
                    return "DeepSeek Harness 在 DSH Studio 的一轮工作遇到错误，请查看结果。"
                case .aborted:
                    return "DeepSeek Harness 在 DSH Studio 的一轮工作已中止。"
                case .maxTokens:
                    return "DeepSeek Harness 在 DSH Studio 的一轮工作已达到输出上限。"
                case .interrupted:
                    return "DeepSeek Harness 在 DSH Studio 的一轮工作被中断。"
                case .other:
                    return "DeepSeek Harness 在 DSH Studio 的一轮工作已结束。"
                }
            case .permissionWaiting: return "DeepSeek Harness 正在等待授权，请回到 DSH Studio 处理后继续。"
            case .questionWaiting: return "DeepSeek Harness 正在等待你的输入，请回到 DSH Studio 回答后继续。"
            }
        }
        switch kind {
        case let .turnCompleted(reason):
            switch reason {
            case .completed:
                return "DeepSeek Harness completed a turn in DSH Studio."
            case .blocked:
                return "A DeepSeek Harness turn ended blocked in DSH Studio."
            case .error:
                return "A DeepSeek Harness turn ended with an error in DSH Studio."
            case .aborted:
                return "A DeepSeek Harness turn was aborted in DSH Studio."
            case .maxTokens:
                return "A DeepSeek Harness turn reached its output limit in DSH Studio."
            case .interrupted:
                return "A DeepSeek Harness turn was interrupted in DSH Studio."
            case .other:
                return "A DeepSeek Harness turn ended in DSH Studio."
            }
        case .permissionWaiting: return "DeepSeek Harness is waiting for authorization. Return to DSH Studio to continue."
        case .questionWaiting: return "DeepSeek Harness is waiting for your input. Return to DSH Studio to continue."
        }
    }
}

private enum AuthorizationState {
    case unknown
    case checking
    case allowed
    case denied
}
