//
//  StudioSettingsReconciler.swift
//  DSH Studio
//

import Foundation

/// The five preferences the app and the Harness settings page share.
///
/// Every field is optional because either side may hold no value for it yet: a fresh
/// installation has defaults on both sides, and a namespace Harness has never written
/// has none at all.
struct StudioSettingsSnapshot: Equatable {
    /// Workspace directory Harness is started in.
    var workspacePath: String?
    /// Maximum width of the conversation column, in CSS pixels.
    var chatContentMaxWidth: Double?
    /// When a completed turn raises a system notification.
    var turnCompletionNotification: String?
    /// Whether permission requests raise a system notification.
    var permissionNotificationsEnabled: Bool?
    /// Whether pending questions raise a system notification.
    var questionNotificationsEnabled: Bool?
}

/// What the app does with the DSH Studio namespace once Harness is ready.
struct StudioSettingsReconciliation: Equatable {
    /// Values Harness holds and the native mirror has to adopt.
    ///
    /// A field stays `nil` when the two sides already agree, so an unchanged setting
    /// never causes a write or a re-render.
    var adopted = StudioSettingsSnapshot(
        workspacePath: nil,
        chatContentMaxWidth: nil,
        turnCompletionNotification: nil,
        permissionNotificationsEnabled: nil,
        questionNotificationsEnabled: nil
    )
    /// Workspace the app has to publish, because only it can admit a directory.
    var publishedWorkspacePath: String?
}

/// Decides what the app does with the settings Harness owns.
///
/// The ownership model this type implements:
///
/// - **Harness Settings is the authoritative persisted configuration.** Once the
///   one-time migration of legacy values has happened, a normal launch reads the
///   namespace and feeds the native mirror from it — never the other way around.
/// - **The Swift store is a startup mirror.** It exists because three of the values
///   have to be known before Harness can start (the layout width the injected CSS uses
///   and the notification switches), and because Harness's own settings document is
///   only readable once the local server is up.
/// - **The mirror must never overwrite authoritative Harness settings.** A value that
///   is in Harness and not in the mirror is adopted, not republished; a stale mirror
///   therefore cannot resurrect a value the user changed in the settings page, and a
///   failed `preference.sync` cannot undo it either.
/// - **One value is the other way round on purpose**: the workspace. Only the app can
///   admit a directory and relaunch Harness against it, so the app publishes the
///   workspace it is actually running with, and the page shows that path.
enum StudioSettingsReconciler {
    /// Computes what one launch reconciles between Harness and the native mirror.
    ///
    /// - Parameters:
    ///   - harness: Values the namespace currently holds.
    ///   - mirror: Values the app has stored for the next launch.
    /// - Returns: The values to adopt and the workspace to publish, if any.
    static func reconcile(
        harness: StudioSettingsSnapshot,
        mirror: StudioSettingsSnapshot
    ) -> StudioSettingsReconciliation {
        var reconciliation = StudioSettingsReconciliation()

        // Harness owns these four, so a difference always resolves in its favour.
        if let stored = harness.chatContentMaxWidth, stored != mirror.chatContentMaxWidth {
            reconciliation.adopted.chatContentMaxWidth = stored
        }
        if let stored = harness.turnCompletionNotification,
           stored != mirror.turnCompletionNotification {
            reconciliation.adopted.turnCompletionNotification = stored
        }
        if let stored = harness.permissionNotificationsEnabled,
           stored != mirror.permissionNotificationsEnabled {
            reconciliation.adopted.permissionNotificationsEnabled = stored
        }
        if let stored = harness.questionNotificationsEnabled,
           stored != mirror.questionNotificationsEnabled {
            reconciliation.adopted.questionNotificationsEnabled = stored
        }

        // The workspace is the app's to publish: it is the only side that can admit
        // the directory and relaunch against it. An empty mirror publishes nothing, so
        // a namespace without a workspace is never cleared by accident.
        if let admitted = mirror.workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !admitted.isEmpty,
           admitted != harness.workspacePath {
            reconciliation.publishedWorkspacePath = admitted
        }

        return reconciliation
    }
}
