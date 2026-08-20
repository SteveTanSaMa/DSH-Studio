//
//  AppModel.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import AppKit
import Combine
import DeepSeekRuntime
import Foundation

/// Coordinates user settings with the RuntimeManager used by the main window.
@MainActor
final class AppModel: ObservableObject {
    @Published var runtime: RuntimeManager

    var settings = SettingsStore()
    private var runtimeCancellable: AnyCancellable?

    init() {
        runtime = RuntimeManager.makeMVP(
            workspace: settings.workspaceURL,
            dshHome: settings.dshHomeURL
        )
        bindRuntime()
        applySettings()
    }

    private func bindRuntime() {
        // RuntimeManager publishes its own state. Forwarding that publisher
        // keeps the SwiftUI view tree in sync when the manager is replaced.
        runtimeCancellable = runtime.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Starts the local Runtime and lets its state drive the initial UI.
    func start() {
        runtime.start()
    }

    func applySettings() {
        // Runtime recovery is an app reliability mechanism, not a user-facing toggle.
        runtime.restartPolicy.enabled = true
    }

    func changeWorkspace(to url: URL) {
        Task { @MainActor [weak self] in
            await self?.changeWorkspaceAndWait(to: url)
        }
    }

    /// Rebuilds the Runtime after the workspace changes because the child
    /// process receives the workspace as its working directory.
    func changeWorkspaceAndWait(to url: URL) async {
        guard url != settings.workspaceURL else { return }
        await runtime.stop()
        settings.workspaceURL = url
        runtime = RuntimeManager.makeMVP(
            workspace: url,
            dshHome: settings.dshHomeURL
        )
        bindRuntime()
        runtime.start()
    }

    /// Rebuilds the Runtime after moving DSH_HOME so the next process uses the
    /// new persistent data directory from its environment.
    func changeDSHHomeAndWait(to url: URL) async {
        guard url != settings.dshHomeURL else { return }
        await runtime.stop()
        settings.dshHomeURL = url
        runtime = RuntimeManager.makeMVP(
            workspace: settings.workspaceURL,
            dshHome: url
        )
        bindRuntime()
        runtime.start()
    }

    @discardableResult
    /// Opens the directory containing the sanitized runtime log files.
    func openLogs() -> Bool {
        let support = RuntimeLocator.applicationSupportDirectory()
        guard let logs = support?.appendingPathComponent("Logs", isDirectory: true) else { return false }
        do {
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        } catch {
            return false
        }
        return NSWorkspace.shared.open(logs)
    }

}

extension RuntimeManager {
    /// Creates the production manager with the current app support locations.
    ///
    /// Development overrides intentionally skip provisioning; release builds
    /// use the verified online provisioner when the Runtime is absent.
    static func makeMVP(workspace: URL, dshHome: URL? = nil) -> RuntimeManager {
        let root = RuntimeLocator.runtimeRoot()
        let support = RuntimeLocator.applicationSupportDirectory()!
        let dshHome = dshHome ?? RuntimeLocator.defaultDSHHome() ?? support
            .appendingPathComponent("DSH_HOME", isDirectory: true)
        let logURL = support
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("runtime.log")
        let configuration = RuntimeConfiguration(
            nodeExecutable: RuntimeLocator.nodeExecutable(root: root),
            harnessEntry: RuntimeLocator.harnessEntry(root: root),
            dshHome: dshHome,
            workspace: workspace,
            pnpmExecutable: RuntimeLocator.pnpmExecutable(root: root)
        )
        let release = RuntimeReleaseCatalog.load(
            architecture: RuntimeLocator.architectureDirectory()
        )
        let provisioner: (any RuntimeProvisioning)? =
            RuntimeLocator.usesDevelopmentOverride() || RuntimeLocator.isBundledRuntimeRoot(root)
            ? nil
            : RuntimeProvisioner(root: root, release: release)
        return RuntimeManager(
            configuration: configuration,
            logFileURL: logURL,
            provisioner: provisioner
        )
    }
}
