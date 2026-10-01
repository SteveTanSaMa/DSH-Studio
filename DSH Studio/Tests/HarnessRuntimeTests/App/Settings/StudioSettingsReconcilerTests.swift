//
//  StudioSettingsReconcilerTests.swift
//  DSH Studio
//

import XCTest

/// Guards the ownership model of the DSH Studio settings namespace.
///
/// Harness Settings is the authority and the Swift store is a startup mirror, so a
/// launch reads Harness and never pushes the mirror back — except for the workspace,
/// which the app owns because only it can admit a directory. These cases are the
/// failure modes that model exists for: a stale mirror, a lost `preference.sync`, and
/// the one-time migration of legacy values.
final class StudioSettingsReconcilerTests: XCTestCase {

    /// Test 1 — a change made in the settings page survives a restart.
    func testHarnessChangePersists() {
        let reconciliation = StudioSettingsReconciler.reconcile(
            harness: snapshot(width: 1200),
            mirror: snapshot(width: 1200)
        )

        XCTAssertEqual(reconciliation.adopted, StudioSettingsSnapshot(
            workspacePath: nil,
            chatContentMaxWidth: nil,
            turnCompletionNotification: nil,
            permissionNotificationsEnabled: nil,
            questionNotificationsEnabled: nil
        ))
        XCTAssertNil(reconciliation.publishedWorkspacePath, "an agreeing launch writes nothing")
    }

    /// Test 2 — Harness wins over a stale mirror; the mirror value is not written back.
    func testHarnessWinsOverAStaleMirror() {
        let reconciliation = StudioSettingsReconciler.reconcile(
            harness: snapshot(width: 1200, permissionNotifications: false),
            mirror: snapshot(width: 1000, permissionNotifications: true)
        )

        XCTAssertEqual(reconciliation.adopted.chatContentMaxWidth, 1200)
        XCTAssertEqual(reconciliation.adopted.permissionNotificationsEnabled, false)
        XCTAssertNil(reconciliation.publishedWorkspacePath)
    }

    /// Test 3 — a lost `preference.sync` cannot undo the value the page stored.
    func testFailedPreferenceSyncIsRecoverable() {
        // The page wrote 1200 into Harness and its `preference.sync` never arrived, so
        // the mirror still holds the old value.
        let stale = StudioSettingsReconciler.reconcile(
            harness: snapshot(width: 1200, turnCompletion: "never"),
            mirror: snapshot(width: 1000, turnCompletion: "whenNotFocused")
        )

        XCTAssertEqual(stale.adopted.chatContentMaxWidth, 1200, "Harness keeps its authority")
        XCTAssertEqual(stale.adopted.turnCompletionNotification, "never")
        XCTAssertNil(stale.publishedWorkspacePath, "the stale mirror is never published back")

        // Applying the adoption is what the app does next; the mirror then agrees, and
        // the following launch has nothing left to fix.
        var repaired = snapshot(width: 1000, turnCompletion: "whenNotFocused")
        repaired.chatContentMaxWidth = stale.adopted.chatContentMaxWidth
        repaired.turnCompletionNotification = stale.adopted.turnCompletionNotification

        let recovered = StudioSettingsReconciler.reconcile(
            harness: snapshot(width: 1200, turnCompletion: "never"),
            mirror: repaired
        )
        XCTAssertEqual(recovered.adopted, StudioSettingsSnapshot(
            workspacePath: nil,
            chatContentMaxWidth: nil,
            turnCompletionNotification: nil,
            permissionNotificationsEnabled: nil,
            questionNotificationsEnabled: nil
        ))
        XCTAssertNil(recovered.publishedWorkspacePath, "the next launch is a no-op again")
    }

    /// Test 4 — after the one-time migration, a divergent mirror does not win.
    func testMigrationIsOneTimeAndTheMirrorCannotRevertIt() {
        // Before the migration the legacy values have not reached Harness yet, so the
        // plugin writes them once; both sides then agree.
        let migrated = StudioSettingsReconciler.reconcile(
            harness: snapshot(width: 900),
            mirror: snapshot(width: 900)
        )
        XCTAssertEqual(migrated.adopted.chatContentMaxWidth, nil)
        XCTAssertNil(migrated.publishedWorkspacePath)

        // Once the marker is set, a mirror that differs means the mirror is out of date.
        let afterMigration = StudioSettingsReconciler.reconcile(
            harness: snapshot(width: 900),
            mirror: snapshot(width: 1500)
        )
        XCTAssertEqual(afterMigration.adopted.chatContentMaxWidth, 900, "Harness remains 900")
        XCTAssertNil(afterMigration.publishedWorkspacePath)
    }

    /// Test 5 — a fresh installation with defaults on both sides is left alone.
    func testNewInstallationWithDefaultsIsUntouched() {
        let reconciliation = StudioSettingsReconciler.reconcile(
            harness: snapshot(),
            mirror: snapshot()
        )

        XCTAssertEqual(reconciliation.adopted, StudioSettingsSnapshot(
            workspacePath: nil,
            chatContentMaxWidth: nil,
            turnCompletionNotification: nil,
            permissionNotificationsEnabled: nil,
            questionNotificationsEnabled: nil
        ))
        XCTAssertNil(reconciliation.publishedWorkspacePath)
    }

    /// A namespace Harness has not written yet leaves the mirror exactly as it is.
    func testAnEmptyNamespaceAdoptsNothing() {
        let reconciliation = StudioSettingsReconciler.reconcile(
            harness: StudioSettingsSnapshot(
                workspacePath: nil,
                chatContentMaxWidth: nil,
                turnCompletionNotification: nil,
                permissionNotificationsEnabled: nil,
                questionNotificationsEnabled: nil
            ),
            mirror: snapshot(width: 1000, permissionNotifications: true)
        )

        XCTAssertEqual(reconciliation.adopted.chatContentMaxWidth, nil)
        XCTAssertEqual(reconciliation.adopted.permissionNotificationsEnabled, nil)
    }

    /// The workspace is the one value the app publishes, and only when it differs.
    func testTheWorkspaceIsTheOnePublishedValue() {
        let published = StudioSettingsReconciler.reconcile(
            harness: snapshot(workspace: "/tmp/old"),
            mirror: snapshot(workspace: "/tmp/admitted")
        )
        XCTAssertEqual(published.publishedWorkspacePath, "/tmp/admitted")
        XCTAssertNil(published.adopted.workspacePath, "the app never adopts a path it did not admit")

        let agreeing = StudioSettingsReconciler.reconcile(
            harness: snapshot(workspace: "/tmp/admitted"),
            mirror: snapshot(workspace: "/tmp/admitted")
        )
        XCTAssertNil(agreeing.publishedWorkspacePath)

        let empty = StudioSettingsReconciler.reconcile(
            harness: snapshot(workspace: "/tmp/old"),
            mirror: snapshot(workspace: "   ")
        )
        XCTAssertNil(empty.publishedWorkspacePath, "a blank workspace never clears the stored one")
    }

    /// Builds a snapshot, defaulting every field to the value a new install starts with.
    ///
    /// - Parameters:
    ///   - workspace: Workspace path; `nil` when the side holds none.
    ///   - width: Content width; defaults to the documented default.
    ///   - turnCompletion: Turn-completion preference; defaults to the documented default.
    ///   - permissionNotifications: Permission notifications; defaults to the default.
    ///   - questionNotifications: Question notifications; defaults to the default.
    /// - Returns: The snapshot.
    private func snapshot(
        workspace: String? = "/Users/example/Workspace",
        width: Double? = 1000,
        turnCompletion: String? = "whenNotFocused",
        permissionNotifications: Bool? = true,
        questionNotifications: Bool? = true
    ) -> StudioSettingsSnapshot {
        StudioSettingsSnapshot(
            workspacePath: workspace,
            chatContentMaxWidth: width,
            turnCompletionNotification: turnCompletion,
            permissionNotificationsEnabled: permissionNotifications,
            questionNotificationsEnabled: questionNotifications
        )
    }
}
