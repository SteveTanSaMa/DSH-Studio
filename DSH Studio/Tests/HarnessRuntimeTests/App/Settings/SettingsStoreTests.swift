//
//  SettingsStoreTests.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import XCTest

@testable import DeepSeekRuntime

/// Verifies app-owned settings persistence and CSS width normalization.
final class SettingsStoreTests: XCTestCase {
    /// The sidebar width is remembered across launches and clamped to the layout range.
    ///
    /// Harness keeps panel geometry in memory, so this store is the only place a dragged
    /// width survives a restart.
    @MainActor
    func testSidebarWidthPersistsAndClamps() {
        let suiteName = "DeepSeekStudio.SettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertNil(store.sidebarWidth, "a first launch has no width to restore")
        XCTAssertNil(defaults.object(forKey: SettingsStore.sidebarWidthKey))

        store.sidebarWidth = 336
        XCTAssertEqual(defaults.double(forKey: SettingsStore.sidebarWidthKey), 336)

        let reopened = SettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.sidebarWidth, 336, "the next launch gets the same width back")

        reopened.sidebarWidth = SettingsStore.sidebarWidthRange.upperBound + 500
        XCTAssertEqual(reopened.sidebarWidth, SettingsStore.sidebarWidthRange.upperBound)
        reopened.sidebarWidth = SettingsStore.sidebarWidthRange.lowerBound - 500
        XCTAssertEqual(reopened.sidebarWidth, SettingsStore.sidebarWidthRange.lowerBound)
    }

    /// A stored sidebar width that cannot be a width is dropped, not guessed.
    @MainActor
    func testInvalidPersistedSidebarWidthIsIgnored() {
        let suiteName = "DeepSeekStudio.SettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("wide", forKey: SettingsStore.sidebarWidthKey)
        let store = SettingsStore(defaults: defaults)

        XCTAssertNil(store.sidebarWidth)
    }

    /// A restored workspace is kept, while the data home stays app-owned.
    @MainActor
    func testWorkspaceCanBeRestoredWhileDataHomeRemainsAppOwned() {
        let suiteName = "DeepSeekStudio.SettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("/tmp/legacy-workspace", forKey: "workspacePath")
        defaults.set("/tmp/legacy-data", forKey: "dshHomePath")
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.workspaceURL.path, "/tmp/legacy-workspace")
        XCTAssertEqual(store.dshHomeURL, RuntimeLocator.defaultDSHHome())
        XCTAssertEqual(defaults.string(forKey: "workspacePath"), "/tmp/legacy-workspace")
        XCTAssertEqual(defaults.string(forKey: "dshHomePath"), "/tmp/legacy-data")
        XCTAssertNil(defaults.object(forKey: "maxWidth"))
        XCTAssertNil(defaults.object(forKey: "automaticRestart"))
    }

    /// The chat width falls back to its default and clamps out-of-range values.
    @MainActor
    func testChatContentMaxWidthDefaultsAndNormalizesBounds() {
        let suiteName = "DeepSeekStudio.SettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.chatContentMaxWidth, SettingsStore.chatContentMaxWidthDefault)

        store.chatContentMaxWidth = SettingsStore.chatContentMaxWidthRange.lowerBound - 1
        XCTAssertEqual(store.chatContentMaxWidth, SettingsStore.chatContentMaxWidthRange.lowerBound)
        XCTAssertEqual(
            defaults.double(forKey: SettingsStore.chatContentMaxWidthKey),
            SettingsStore.chatContentMaxWidthRange.lowerBound
        )

        store.chatContentMaxWidth = SettingsStore.chatContentMaxWidthRange.upperBound + 1
        XCTAssertEqual(store.chatContentMaxWidth, SettingsStore.chatContentMaxWidthRange.upperBound)
        XCTAssertEqual(
            defaults.double(forKey: SettingsStore.chatContentMaxWidthKey),
            SettingsStore.chatContentMaxWidthRange.upperBound
        )
    }

    /// A stored width that is not a number falls back to the default.
    @MainActor
    func testInvalidPersistedChatContentMaxWidthFallsBackToDefault() {
        let suiteName = "DeepSeekStudio.SettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Double.nan, forKey: SettingsStore.chatContentMaxWidthKey)
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.chatContentMaxWidth, SettingsStore.chatContentMaxWidthDefault)
    }

    /// Notification preferences start at their defaults and persist changes.
    @MainActor
    func testNotificationSettingsUseDefaultsAndPersist() {
        let suiteName = "DeepSeekStudio.SettingsStoreTests.notifications.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(
            store.turnCompletionNotification,
            SettingsStore.turnCompletionNotificationDefault
        )
        XCTAssertTrue(store.permissionNotificationsEnabled)
        XCTAssertTrue(store.questionNotificationsEnabled)

        store.turnCompletionNotification = .always
        store.permissionNotificationsEnabled = false
        store.questionNotificationsEnabled = false

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.turnCompletionNotification, .always)
        XCTAssertFalse(reloaded.permissionNotificationsEnabled)
        XCTAssertFalse(reloaded.questionNotificationsEnabled)
    }

    /// An unrecognized stored preference falls back to the default.
    @MainActor
    func testInvalidPersistedTurnCompletionNotificationFallsBackToDefault() {
        let suiteName = "DeepSeekStudio.SettingsStoreTests.invalidNotifications.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("unsupported", forKey: SettingsStore.turnCompletionNotificationKey)
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(
            store.turnCompletionNotification,
            SettingsStore.turnCompletionNotificationDefault
        )
    }
}
