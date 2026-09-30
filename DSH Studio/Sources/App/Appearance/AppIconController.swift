//
//  AppIconController.swift
//  DSH Studio
//

import AppKit
import Foundation

/// Keeps the running app's icon in step with the system appearance.
///
/// The bundle icon is the light artwork, and macOS has no appearance-aware bundle
/// icon on the versions this app supports — a `mac` appiconset cannot carry a dark
/// appearance, so `actool` drops one. The dark artwork is therefore applied to the
/// running app instead: the Dock, the app switcher, and the About panel follow the
/// system appearance, while Finder keeps showing the light icon.
@MainActor
final class AppIconController {
    /// The two brand artworks shipped with the app.
    enum Artwork: String, CaseIterable {
        /// Artwork for a light appearance; the same file the bundle icon is cut from.
        case light = "AppLogoLight"
        /// Artwork for a dark appearance.
        case dark = "AppLogoDark"
    }

    /// The part of the app this controller drives.
    ///
    /// Narrowed to what an icon swap needs, so the choice of artwork can be checked
    /// without a running application. It is main-actor bound because the icon and the
    /// appearance it follows both belong to the main thread.
    @MainActor
    protocol Host: AnyObject {
        /// Appearance the icon has to match.
        var effectiveAppearance: NSAppearance { get }
        /// Icon the Dock, the app switcher, and the About panel show.
        var applicationIconImage: NSImage? { get set }
    }

    /// The running application, seen through the slice above.
    ///
    /// AppKit's own property does not satisfy the protocol directly, so the
    /// application is adapted rather than made to conform.
    @MainActor
    private final class ApplicationHost: Host {
        private let application: NSApplication

        /// Creates the adapter for one application.
        ///
        /// - Parameter application: Application whose icon is replaced.
        init(application: NSApplication) {
            self.application = application
        }

        /// Appearance the application currently resolves to.
        var effectiveAppearance: NSAppearance { application.effectiveAppearance }

        /// Icon the application shows in the Dock.
        var applicationIconImage: NSImage? {
            get { application.applicationIconImage }
            set { application.applicationIconImage = newValue }
        }
    }

    /// The app whose icon is replaced, and whose appearance is followed.
    private let host: any Host
    /// Loads one artwork; injected so the choice can be tested without a bundle.
    private let loadArtwork: (Artwork) -> NSImage?
    /// Observation that reapplies the artwork when the system appearance changes.
    private var observation: NSKeyValueObservation?

    /// Creates a controller.
    ///
    /// - Parameters:
    ///   - host: Application to update; the shared one when omitted. It is resolved
    ///     here rather than as a default argument, which would not be main-actor bound.
    ///   - loadArtwork: Artwork loader; the app bundle's images by default.
    init(
        host: (any Host)? = nil,
        loadArtwork: @escaping (Artwork) -> NSImage? = AppIconController.bundledArtwork
    ) {
        self.host = host ?? ApplicationHost(application: NSApplication.shared)
        self.loadArtwork = loadArtwork
    }

    /// Applies the artwork the current appearance asks for, then follows changes.
    func start() {
        apply(for: host.effectiveAppearance)
        // Only a real application reports later appearance changes: the observable
        // key path belongs to `NSApplication`, not to the slice above.
        guard let application = host as? NSApplication else { return }
        observation = application.observe(\.effectiveAppearance, options: [.new]) { [weak self] app, _ in
            // KVO for an app's appearance arrives on the main thread, which is where
            // the icon has to be replaced anyway.
            MainActor.assumeIsolated {
                self?.apply(for: app.effectiveAppearance)
            }
        }
    }

    /// Applies the artwork matching one appearance.
    ///
    /// - Parameter appearance: Appearance to match; an unknown appearance counts as
    ///   light, which is the artwork the bundle icon already carries.
    func apply(for appearance: NSAppearance) {
        guard let image = loadArtwork(Self.artwork(for: appearance)) else { return }
        host.applicationIconImage = image
    }

    /// The artwork one appearance asks for.
    ///
    /// - Parameter appearance: Appearance to match.
    /// - Returns: ``Artwork/dark`` for the dark appearance, ``Artwork/light`` otherwise.
    static func artwork(for appearance: NSAppearance) -> Artwork {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    /// Loads one artwork from the app bundle.
    ///
    /// - Parameter artwork: Artwork to load.
    /// - Returns: The image, or `nil` when the bundle does not carry it.
    private static func bundledArtwork(_ artwork: Artwork) -> NSImage? {
        NSImage(named: artwork.rawValue)
    }
}
