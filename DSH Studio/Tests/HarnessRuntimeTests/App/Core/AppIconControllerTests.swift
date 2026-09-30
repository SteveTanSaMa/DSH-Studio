//
//  AppIconControllerTests.swift
//  DSH Studio
//

import AppKit
import XCTest

/// Guards that the running app's icon follows the system appearance.
///
/// A macOS appiconset cannot carry a dark appearance, so the dark artwork is applied
/// to the running app instead; a regression here would leave the Dock showing the
/// light artwork on a dark system.
@MainActor
final class AppIconControllerTests: XCTestCase {

    /// The app the controller drives, without an application instance.
    private final class FakeHost: AppIconController.Host {
        /// Appearance the controller reads; light until a test says otherwise.
        var effectiveAppearance: NSAppearance = NSAppearance(named: .aqua)!
        /// Icon the controller wrote, if any.
        var applicationIconImage: NSImage?
    }

    /// Each appearance asks for its own artwork.
    func testArtworkMatchesTheAppearance() throws {
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let light = try XCTUnwrap(NSAppearance(named: .aqua))

        XCTAssertEqual(AppIconController.artwork(for: dark), .dark)
        XCTAssertEqual(AppIconController.artwork(for: light), .light)
    }

    /// Applying an appearance swaps in the artwork that belongs to it.
    func testApplyingAnAppearanceUsesTheMatchingArtwork() throws {
        let host = FakeHost()
        let dark = NSImage(size: NSSize(width: 32, height: 32))
        let light = NSImage(size: NSSize(width: 32, height: 32))
        var requested: [AppIconController.Artwork] = []
        let controller = AppIconController(host: host) { artwork in
            requested.append(artwork)
            return artwork == .dark ? dark : light
        }

        controller.apply(for: try XCTUnwrap(NSAppearance(named: .darkAqua)))
        XCTAssertEqual(requested, [.dark])
        XCTAssertTrue(host.applicationIconImage === dark)

        controller.apply(for: try XCTUnwrap(NSAppearance(named: .aqua)))
        XCTAssertEqual(requested, [.dark, .light])
        XCTAssertTrue(host.applicationIconImage === light)
    }

    /// Starting applies the artwork the app's current appearance asks for.
    func testStartAppliesTheCurrentAppearance() throws {
        let host = FakeHost()
        host.effectiveAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        var requested: [AppIconController.Artwork] = []
        let controller = AppIconController(host: host) { artwork in
            requested.append(artwork)
            return NSImage(size: NSSize(width: 32, height: 32))
        }

        controller.start()

        XCTAssertEqual(requested, [.dark])
    }

    /// Artwork the bundle cannot supply leaves the icon it already had in place.
    func testMissingArtworkKeepsTheExistingIcon() {
        let host = FakeHost()
        let existing = NSImage(size: NSSize(width: 16, height: 16))
        host.applicationIconImage = existing
        let controller = AppIconController(host: host) { _ in nil }

        controller.start()

        XCTAssertTrue(host.applicationIconImage === existing)
    }
}
