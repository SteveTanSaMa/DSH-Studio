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
    @MainActor
    func testWorkspaceAndDataHomeUseFixedAppOwnedLocations() {
        let suiteName = "DeepSeekStudio.SettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("/tmp/legacy-workspace", forKey: "workspacePath")
        defaults.set("/tmp/legacy-data", forKey: "dshHomePath")
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.workspaceURL, RuntimeLocator.defaultWorkspace())
        XCTAssertEqual(store.dshHomeURL, RuntimeLocator.defaultDSHHome())
        XCTAssertEqual(defaults.string(forKey: "workspacePath"), "/tmp/legacy-workspace")
        XCTAssertEqual(defaults.string(forKey: "dshHomePath"), "/tmp/legacy-data")
        XCTAssertNil(defaults.object(forKey: "maxWidth"))
        XCTAssertNil(defaults.object(forKey: "automaticRestart"))
    }

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

    @MainActor
    func testInvalidPersistedChatContentMaxWidthFallsBackToDefault() {
        let suiteName = "DeepSeekStudio.SettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Double.nan, forKey: SettingsStore.chatContentMaxWidthKey)
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.chatContentMaxWidth, SettingsStore.chatContentMaxWidthDefault)
    }

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
