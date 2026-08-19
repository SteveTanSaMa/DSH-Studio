//
//  HarnessWebViewSessionExport.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import AppKit
import DeepSeekHarness
import DeepSeekLogging
import Foundation
import UniformTypeIdentifiers
import WebKit

/// Native Session log export actions used by the WebView coordinator.
///
/// Harness still owns the export request and its data format. The macOS shell
/// only intercepts the loopback download so it can present an `NSSavePanel`,
/// validate the ZIP, and commit it atomically to the user's selected location.
extension HarnessWebView.Coordinator {
    /// Starts the native export without blocking WebKit's navigation delegate.
    func startSessionExport(from url: URL, webView: WKWebView) {
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            await self.performSessionExport(from: url, webView: webView)
        }
    }

    /// Downloads to a temporary location before showing the save panel.
    ///
    /// The temporary file is discarded on cancellation and on every failure.
    /// This keeps incomplete or non-ZIP responses out of the user's chosen
    /// directory and leaves no partial destination behind.
    @MainActor
    private func performSessionExport(from url: URL, webView: WKWebView) async {
        guard runtime.state == .ready, let baseURL = runtime.readyURL else {
            presentExportAlert(
                title: "无法导出 Session log",
                message: LogRedactor.redact(SessionLogExportError.runtimeUnavailable.localizedDescription),
                style: .warning,
                webView: webView
            )
            return
        }
        guard let sessionID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "sessionId" })?.value,
              !sessionID.isEmpty else {
            presentExportAlert(
                title: "无法导出 Session log",
                message: LogRedactor.redact(SessionLogExportError.emptySessionID.localizedDescription),
                style: .warning,
                webView: webView
            )
            return
        }

        var stagedURL: URL?
        do {
            stagedURL = try await sessionLogClient.stage(sessionID: sessionID, baseURL: baseURL)
            guard let stagedFile = stagedURL else { throw SessionLogExportError.emptyResponse }
            let destination = await chooseExportDestination(
                filename: SessionLogExport.filename(sessionID: sessionID),
                webView: webView
            )
            guard let destination else {
                sessionLogClient.discard(stagedURL: stagedFile)
                presentExportAlert(
                    title: "Session log 导出已取消",
                    message: "未保存文件。",
                    style: .informational,
                    webView: webView
                )
                return
            }
            try sessionLogClient.commit(stagedURL: stagedFile, to: destination)
            stagedURL = nil
            runtime.logs.log(
                component: "WebView",
                level: "info",
                message: "session log saved to \(destination.path)"
            )
        } catch {
            if let stagedURL {
                sessionLogClient.discard(stagedURL: stagedURL)
            }
            runtime.logs.log(
                component: "WebView",
                level: "error",
                message: "session log export failed: \(error.localizedDescription)"
            )
            presentExportAlert(
                title: "Session log 导出失败",
                message: LogRedactor.redact(error.localizedDescription),
                style: .critical,
                webView: webView
            )
        }
    }

    /// Presents a directory-aware save panel for the validated ZIP archive.
    @MainActor
    private func chooseExportDestination(filename: String, webView: WKWebView) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return await withCheckedContinuation { continuation in
            if let window = webView.window {
                panel.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            } else {
                let response = panel.runModal()
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    /// Reports an export failure in the native window instead of Harness's
    /// browser feedback modal, which has already been intercepted.
    @MainActor
    private func presentExportAlert(
        title: String,
        message: String,
        style: NSAlert.Style,
        webView: WKWebView
    ) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        if let window = webView.window {
            alert.beginSheetModal(for: window)
        } else {
            _ = alert.runModal()
        }
    }
}
