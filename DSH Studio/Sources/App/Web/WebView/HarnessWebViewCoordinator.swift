//
//  HarnessWebViewCoordinator.swift
//  DSH Studio
//

import Combine
import DeepSeekHarness
import DeepSeekRuntime
import Foundation
import WebKit

/// Owns the mutable WebKit delegate state for one WebView.
///
/// The navigation, settings, and session-export extensions all read and write this
/// state, so it lives in one place instead of being duplicated per extension.
extension HarnessWebView {
    /// Shared delegate state for one WebView.
    final class Coordinator: NSObject {
        /// Runtime whose ready URL and data home the page is bound to.
        var runtime: RuntimeManager
        /// Model that owns the settings the page may read and edit.
        let model: AppModel
        /// The one Runtime URL this WebView may navigate to.
        var allowedURL: URL?
        /// Called when WebKit kills the content process, so the host can recover.
        var onWebContentTerminated: () -> Void
        /// The WebView itself; weak because WebKit already owns it.
        weak var webView: WKWebView?
        /// Reloads already attempted for the current URL, bounding the retry loop.
        var reloadAttempts = 0
        // The export extension owns the workflow; the client lives here so the
        // coordinator keeps one staging directory and one cleanup owner.
        /// Session-log client shared by the export workflow.
        ///
        /// It lives on the coordinator so there is one staging directory and one cleanup
        /// owner per WebView.
        let sessionLogClient = SessionLogDownloadClient()
        private var modelCancellable: AnyCancellable?

        /// Creates the coordinator and subscribes to model changes.
        ///
        /// The subscription pushes app settings into the page whenever the model changes,
        /// so a native edit never leaves the page showing a stale value.
        ///
        /// - Parameters:
        ///   - runtime: Runtime the page is bound to.
        ///   - model: Model owning the app settings.
        ///   - onWebContentTerminated: Called when WebKit terminates the content process.
        init(
            runtime: RuntimeManager,
            model: AppModel,
            onWebContentTerminated: @escaping () -> Void
        ) {
            self.runtime = runtime
            self.model = model
            self.onWebContentTerminated = onWebContentTerminated
            super.init()
            modelCancellable = model.objectWillChange.sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.broadcastAppSettingsState()
                }
            }
        }

        /// Cancels the model subscription when the coordinator goes away.
        deinit {
            modelCancellable?.cancel()
        }
    }
}
