//
//  SettingsStoreTests.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import XCTest

@testable import DeepSeekRuntime

/// Verifies persistence boundaries and CSS width normalization.
final class SettingsStoreTests: XCTestCase {
    @MainActor
    func testInjectedDefaultsRemainTheOnlyWriteTarget() {
        let suiteName = "DeepSeekStudio.SettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        let workspace = URL(fileURLWithPath: "/tmp/deepseek-studio-test-workspace", isDirectory: true)
        store.workspaceURL = workspace
        let dshHome = URL(fileURLWithPath: "/tmp/deepseek-studio-test-data", isDirectory: true)
        store.dshHomeURL = dshHome
        store.chatContentMaxWidth = 1360

        XCTAssertEqual(defaults.string(forKey: "workspacePath"), workspace.path)
        XCTAssertEqual(defaults.string(forKey: SettingsStore.dshHomeKey), dshHome.path)
        XCTAssertEqual(defaults.double(forKey: SettingsStore.chatContentMaxWidthKey), 1360)
        XCTAssertNil(defaults.object(forKey: "maxWidth"))
        XCTAssertNil(defaults.object(forKey: "automaticRestart"))

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.dshHomeURL, dshHome)
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
}
