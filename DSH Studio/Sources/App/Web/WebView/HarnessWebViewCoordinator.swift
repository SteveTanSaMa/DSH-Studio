//
//  HarnessWebViewCoordinator.swift
//  DSH Studio
//

import Combine
import DeepSeekHarness
import DeepSeekRuntime
import Foundation
import WebKit

/// Owns the mutable WebKit delegate state shared by the navigation, settings,
/// and session-export extensions.
extension HarnessWebView {
    final class Coordinator: NSObject {
        var runtime: RuntimeManager
        let model: AppModel
        var allowedURL: URL?
        var onWebContentTerminated: () -> Void
        weak var webView: WKWebView?
        var reloadAttempts = 0
        // The export extension owns the workflow; the client lives here so the
        // coordinator keeps one staging directory and one cleanup owner.
        let sessionLogClient = SessionLogDownloadClient()
        private var modelCancellable: AnyCancellable?

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

        deinit {
            modelCancellable?.cancel()
        }
    }
}
