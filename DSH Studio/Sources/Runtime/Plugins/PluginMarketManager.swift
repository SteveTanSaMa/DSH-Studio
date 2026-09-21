//
//  PluginMarketManager.swift
//  DSH Studio
//

import Combine
import Foundation

/// Native lifecycle and recovery coordinator for the fixed dsh-market plugin.
///
/// The community plugin inventory and all third-party plugin operations stay in
/// dsh-market's own Web UI; this type only installs, enables, repairs, and removes
/// the pinned package inside the managed profile.
/// Native lifecycle and recovery coordinator for the fixed dsh-market plugin.
/// The community plugin inventory and all third-party plugin operations remain
/// in dsh-market's own Web UI.
@MainActor
public final class PluginMarketManager: ObservableObject {
    @Published public private(set) var state: PluginMarketState

    /// The Runtime whose profile and process this manager drives.
    public let runtime: RuntimeManager
    /// A store resolved against the current Runtime data home.
    ///
    /// Runtime updates can activate an isolated `DSH_HOME`, so retaining one store
    /// instance would make later market operations mutate the previous data profile.
    public var profileStore: PluginMarketProfileStore {
        PluginMarketProfileStore(
            dshHome: runtime.configuration.dshHome,
            fileManager: fileManager
        )
    }

    private let commandRunner: any RuntimeCommandRunning
    private let httpClient: PluginMarketHTTPClient
    private let operationRecordURL: URL?
    private let fileManager: FileManager
    private var activeOperation: PluginMarketOperation?

    /// Creates a manager bound to one Runtime.
    ///
    /// The initial state is `checking`; call ``refresh()`` to inspect the profile.
    ///
    /// - Parameters:
    ///   - runtime: Runtime whose profile hosts the market.
    ///   - commandRunner: Command seam used for pnpm operations.
    ///   - httpClient: Client for the market's own HTTP routes.
    ///   - supportDirectory: App support directory for the last-operation record.
    ///   - fileManager: File system seam used by tests.
    public init(
        runtime: RuntimeManager,
        commandRunner: any RuntimeCommandRunning = SystemRuntimeCommandRunner(),
        httpClient: PluginMarketHTTPClient = PluginMarketHTTPClient(),
        supportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.runtime = runtime
        self.commandRunner = commandRunner
        self.httpClient = httpClient
        self.fileManager = fileManager
        self.operationRecordURL = supportDirectory?.standardizedFileURL
            .appendingPathComponent("PluginMarket", isDirectory: true)
            .appendingPathComponent("last-operation.json", isDirectory: false)
        self.state = PluginMarketState(
            installState: .checking,
            compatibleHarness: Self.isHarnessCompatible(runtime),
            profileDirectory: PluginMarketProfileStore(
                dshHome: runtime.configuration.dshHome,
                fileManager: fileManager
            ).profileDirectory.path,
            lastOperation: Self.loadOperationRecord(
                from: self.operationRecordURL,
                fileManager: fileManager
            )
        )
    }

    /// Whether an operation started by this manager is still running.
    public var isBusy: Bool {
        activeOperation != nil
    }

    /// Re-inspects the profile and the market's routes, then publishes the result.
    ///
    /// While another operation is running the state is only marked busy, so a
    /// refresh can never interleave with a profile mutation.
    public func refresh() async {
        guard activeOperation == nil else {
            state = stateCopy(busy: true)
            return
        }
        guard isSupportedProfile else {
            state = PluginMarketState(
                installState: .unavailable,
                compatibleHarness: Self.isHarnessCompatible(runtime),
                enabled: false,
                busy: false,
                profileDirectory: profileStore.profileDirectory.path,
                statusError: "仅 web Profile 可用",
                lastOperation: state.lastOperation
            )
            return
        }
        let record = state.lastOperation
        let retainedOperationError = record?.succeeded == false ? state.statusError : nil
        do {
            let inspection = try profileStore.inspect()
            let compatibleHarness = Self.isHarnessCompatible(runtime)
            let hasMarketFootprint = inspection.dependencySpec != nil
                || inspection.bundleListed
                || inspection.installedVersion != nil
                || (inspection.packageJSONPresent && !inspection.packageManifestValid)
            let installed = inspection.dependencySpec == PluginMarketRelease.packageVersion
                && inspection.installedVersion == PluginMarketRelease.packageVersion
            let packageValid = installed
                && inspection.packageManifestValid
                && inspection.bundleListed
                && inspection.bundlePatchValid
                && inspection.entryPointValid
                && inspection.lockIntegrityValid
            var routeAvailable = false
            var marketVersion: String?
            var latestVersion: String?
            var updateAvailable = false
            var statusError: String?

            if runtime.state == .ready, let baseURL = runtime.readyURL {
                do {
                    let status = try await httpClient.status(baseURL: baseURL)
                    routeAvailable = true
                    marketVersion = status.version
                    statusError = status.error
                    if let updates = try? await httpClient.updates(baseURL: baseURL) {
                        let own = updates.updates[PluginMarketRelease.packageName]
                            ?? updates.updates["dsh-market"]
                        latestVersion = own?.latest
                        updateAvailable = own?.updateAvailable == true
                    }
                } catch {
                    statusError = error.localizedDescription
                }
            }

            let installState: PluginMarketInstallState
            if !compatibleHarness {
                installState = .incompatible
            } else if isRuntimeUnavailable {
                installState = .runtimeUnavailable
            } else if !hasMarketFootprint {
                installState = .notInstalled
            } else if !packageValid {
                installState = .corrupted
            } else if !inspection.enabled {
                installState = .disabled
            } else if runtime.state == .ready && !routeAvailable {
                installState = .unavailable
            } else {
                installState = .installed
            }

            state = PluginMarketState(
                installState: installState,
                installedVersion: inspection.installedVersion,
                latestVersion: latestVersion ?? marketVersion,
                updateAvailable: updateAvailable,
                compatibleHarness: compatibleHarness,
                enabled: inspection.enabled,
                routeAvailable: routeAvailable,
                busy: isBusy,
                profileDirectory: profileStore.profileDirectory.path,
                statusError: statusError ?? retainedOperationError,
                lastOperation: record
            )
        } catch {
            state = PluginMarketState(
                installState: .unavailable,
                compatibleHarness: Self.isHarnessCompatible(runtime),
                enabled: false,
                busy: isBusy,
                profileDirectory: profileStore.profileDirectory.path,
                statusError: error.localizedDescription,
                lastOperation: record
            )
        }
    }

    /// Installs the pinned market package into the managed profile.
    ///
    /// - Throws: ``PluginMarketManagerError`` when the profile is unsupported or
    ///   malformed, or the Runtime is not ready; the command's own failure is
    ///   surfaced as ``PluginMarketManagerError/commandFailed(_:)``.
    public func install() async throws {
        try await perform(.install) { [weak self] in
            guard let self else { return }
            try await self.runPluginCommand([
                "add",
                "\(PluginMarketRelease.packageName)@\(PluginMarketRelease.packageVersion)",
                "--save-exact",
            ])
            _ = try self.profileStore.validateExpectedInstallation()
        }
    }

    /// Installs the fixed market package once the Runtime is available.
    ///
    /// Existing valid installations are left to dsh-market to manage.
    @discardableResult
    public func ensureInstalled() async throws -> Bool {
        guard activeOperation == nil else { return false }
        try ensureSupportedProfile()
        await refresh()
        guard state.compatibleHarness else { return false }
        switch state.installState {
        case .notInstalled, .corrupted:
            try await install()
            return true
        case .checking, .runtimeUnavailable, .installed, .disabled, .incompatible, .unavailable:
            return false
        }
    }

    /// Reinstalls the pinned version, replacing whatever the profile holds.
    ///
    /// - Throws: ``PluginMarketManagerError`` when the profile is unsupported or
    ///   malformed, or the install cannot be validated afterwards.
    public func update() async throws {
        try await perform(.update) { [weak self] in
            guard let self else { return }
            try await self.runPluginCommand([
                "add",
                "\(PluginMarketRelease.packageName)@\(PluginMarketRelease.packageVersion)",
                "--save-exact",
            ])
            _ = try self.profileStore.validateExpectedInstallation()
        }
    }

    /// Reinstalls a corrupted or incomplete market installation.
    ///
    /// - Throws: ``PluginMarketManagerError`` when the profile is unsupported or
    ///   malformed, or the repaired install cannot be validated.
    public func repair() async throws {
        try await perform(.repair) { [weak self] in
            guard let self else { return }
            try await self.runPluginCommand([
                "add",
                "\(PluginMarketRelease.packageName)@\(PluginMarketRelease.packageVersion)",
                "--save-exact",
            ])
            _ = try self.profileStore.validateExpectedInstallation()
        }
    }

    /// Activates the market in the profile patch and verifies the write.
    ///
    /// - Throws: ``PluginMarketManagerError`` when the patch cannot be written or the
    ///   new state is not readable afterwards.
    public func enable() async throws {
        try await perform(.enable) { [weak self] in
            guard let self else { return }
            try self.profileStore.setMarketEnabled(true)
            guard try self.profileStore.isMarketEnabled() else {
                throw PluginMarketManagerError.malformedProfile("Plugin Market 启用状态未写入")
            }
        }
    }

    /// Disables the market in the profile patch and verifies the write.
    ///
    /// - Throws: ``PluginMarketManagerError`` when the patch cannot be written or the
    ///   new state is not readable afterwards.
    public func disable() async throws {
        try await perform(.disable) { [weak self] in
            guard let self else { return }
            try self.profileStore.setMarketEnabled(false)
            guard try !self.profileStore.isMarketEnabled() else {
                throw PluginMarketManagerError.malformedProfile("Plugin Market 禁用状态未写入")
            }
        }
    }

    /// Removes the package and its profile entry, then verifies no trace remains.
    ///
    /// - Throws: ``PluginMarketManagerError`` when the removal or the absence check
    ///   fails, in which case the profile is restored from its snapshot.
    public func uninstall() async throws {
        try await perform(.uninstall) { [weak self] in
            guard let self else { return }
            try await self.runPluginCommand(["remove", PluginMarketRelease.packageName])
            try self.profileStore.removeMarketEntry()
            try self.profileStore.validateMarketAbsent()
        }
    }

    /// Returns a native diagnostic bundle when the market Web UI cannot load.
    public func diagnostics() async -> String {
        var lines = [
            "DSH Studio Plugin Market",
            "Package: \(PluginMarketRelease.packageName)@\(PluginMarketRelease.packageVersion)",
            "Source: \(PluginMarketRelease.sourceDescription)",
            "Integrity: \(PluginMarketRelease.packageIntegrity)",
            "Profile: \(profileStore.profileDirectory.path)",
            "Harness: \(runtime.harnessVersion ?? "unknown")",
            "Runtime state: \(runtime.state)",
            "Install state: \(state.installState.rawValue)",
            "Installed version: \(state.installedVersion ?? "unknown")",
            "Route available: \(state.routeAvailable)",
            "Enabled: \(state.enabled)",
            "Last error: \(state.statusError ?? "none")",
        ]

        guard runtime.state == .ready, let baseURL = runtime.readyURL else {
            return lines.joined(separator: "\n")
        }
        do {
            let check = try await httpClient.check(baseURL: baseURL)
            lines.append("\n/dsh-market/check:\n\(String(decoding: check, as: UTF8.self))")
        } catch {
            lines.append("\n/dsh-market/check error: \(error.localizedDescription)")
        }
        do {
            let logs = try await httpClient.logs(baseURL: baseURL)
            lines.append("\n/dsh-market/logs:\n\(logs)")
        } catch {
            lines.append("\n/dsh-market/logs error: \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }

    private func perform(
        _ operation: PluginMarketOperation,
        action: @escaping @MainActor () async throws -> Void
    ) async throws {
        guard activeOperation == nil else {
            throw PluginMarketManagerError.operationInProgress
        }
        try ensureSupportedProfile()
        guard !isRuntimeTransitioning else {
            throw PluginMarketManagerError.runtimeBusy
        }

        activeOperation = operation
        state = stateCopy(busy: true, statusError: .set(nil))
        let wasRunning = runtime.state == .ready
        var snapshot: PluginMarketProfileSnapshot?
        var operationError: Error?

        do {
            try profileStore.ensureProfileDirectory()
            snapshot = try profileStore.snapshot()
            try validateHarness()
            if wasRunning {
                await runtime.stop()
                guard runtime.state == .terminated || runtime.state == .idle else {
                    throw PluginMarketManagerError.runtimeBusy
                }
            }
            try await action()
        } catch {
            operationError = error
            if let snapshot {
                do {
                    try profileStore.restore(snapshot)
                } catch {
                    operationError = PluginMarketManagerError.recoveryFailed(
                        "原始 Profile 无法恢复：\(error.localizedDescription)"
                    )
                }
            }
        }

        if wasRunning {
            do {
                try await restartRuntimeAndWait()
            } catch let restartError {
                // A profile mutation that leaves Runtime unable to boot must
                // not be reported as successful. Restore the pre-operation
                // files and make one recovery start attempt before surfacing
                // the failure.
                if let snapshot {
                    do {
                        try profileStore.restore(snapshot)
                        try await restartRuntimeAndWait()
                        if operationError == nil {
                            operationError = restartError
                        }
                    } catch {
                        operationError = PluginMarketManagerError.recoveryFailed(
                            "Runtime 重启失败，且原始 Profile 恢复后仍无法启动：\(error.localizedDescription)"
                        )
                    }
                } else if operationError == nil {
                    operationError = restartError
                }
            }
        }

        activeOperation = nil
        let record = PluginMarketOperationRecord(
            operation: operation,
            succeeded: operationError == nil,
            message: operationError?.localizedDescription ?? "完成",
            date: Date()
        )
        persist(record)
        state = stateCopy(
            busy: false,
            statusError: .set(operationError?.localizedDescription),
            lastOperation: record
        )
        await refresh()
        if let operationError { throw operationError }
    }

    /// Whether an installed Harness matches the version its installation declares.
    ///
    /// The comparison is against the Runtime's own manifest rather than a version
    /// compiled into the app, so the market keeps working as the Runtime moves ahead
    /// of the app's fallback pin. A mismatch still means the installation is
    /// inconsistent, which is why it is reported instead of ignored.
    ///
    /// - Parameter runtime: Runtime whose installed Harness is compared.
    /// - Returns: `true` when the installed version matches the declared one.
    private static func isHarnessCompatible(_ runtime: RuntimeManager) -> Bool {
        runtime.harnessVersion == runtime.configuration.expectedHarnessVersion
    }

    private func validateHarness() throws {
        guard Self.isHarnessCompatible(runtime) else {
            let actual = runtime.harnessVersion
            let expected = runtime.configuration.expectedHarnessVersion
            throw PluginMarketManagerError.incompatibleHarness(
                expected: expected,
                actual: actual
            )
        }
        guard fileManager.isExecutableFile(atPath: runtime.configuration.nodeExecutable.path),
              fileManager.fileExists(atPath: runtime.configuration.harnessEntry.path),
              let pnpm = runtime.configuration.pnpmExecutable,
              fileManager.isExecutableFile(atPath: pnpm.path) else {
            throw PluginMarketManagerError.runtimeNotReady
        }
    }

    private var isRuntimeTransitioning: Bool {
        switch runtime.state {
        case .provisioning, .updating, .rollingBack, .launching, .starting, .stopping:
            return true
        case .idle, .ready, .failed, .terminated, .crashed:
            return false
        }
    }

    private var isSupportedProfile: Bool {
        runtime.configuration.profileName == PluginMarketRelease.profileName
    }

    private func ensureSupportedProfile() throws {
        guard isSupportedProfile else {
            throw PluginMarketManagerError.unavailable("仅 web Profile 可用")
        }
    }

    private var isRuntimeUnavailable: Bool {
        switch runtime.state {
        case .idle, .ready, .terminated:
            return false
        case .provisioning, .updating, .rollingBack, .launching, .starting, .stopping, .failed, .crashed:
            return true
        }
    }

    private func runPluginCommand(_ pluginArguments: [String]) async throws {
        let configuration = runtime.configuration
        let commandArguments = [
            configuration.harnessEntry.path,
            "plugin",
            "--profile",
            PluginMarketRelease.profileName,
        ] + pluginArguments
        var environment = ProcessInfo.processInfo.environment
        environment["DSH_HOME"] = configuration.dshHome.path
        environment["DSH_TELEMETRY_DISABLED"] = "1"
        environment["NARB_DISABLE_NATIVE_CACHE"] = "1"
        let registry = PluginMarketRelease.registryURL.absoluteString + "/"
        environment["npm_config_registry"] = registry
        environment["NPM_CONFIG_REGISTRY"] = registry
        environment["npm_config_audit"] = "false"
        environment["npm_config_fund"] = "false"
        environment["npm_config_ignore_scripts"] = "true"
        environment["NPM_CONFIG_IGNORE_SCRIPTS"] = "true"
        environment["CI"] = "1"
        for (key, value) in configuration.environment {
            environment[key] = value
        }
        // dsh-market is a fixed, already-built tarball. Native management must
        // never execute package install hooks, even if a caller supplied an
        // overriding Runtime environment.
        environment["npm_config_ignore_scripts"] = "true"
        environment["NPM_CONFIG_IGNORE_SCRIPTS"] = "true"
        var pathEntries = [configuration.nodeExecutable.deletingLastPathComponent().path]
        if let pnpm = configuration.pnpmExecutable {
            pathEntries.insert(pnpm.deletingLastPathComponent().path, at: 0)
        }
        if let inherited = environment["PATH"], !inherited.isEmpty {
            pathEntries.append(inherited)
        }
        environment["PATH"] = pathEntries.joined(separator: ":")

        let result: RuntimeCommandResult
        let commandRunner = self.commandRunner
        do {
            result = try await Task.detached(priority: .userInitiated) {
                try commandRunner.run(
                    executable: configuration.nodeExecutable,
                    arguments: commandArguments,
                    currentDirectory: configuration.workspace,
                    environment: environment
                )
            }.value
        } catch {
            throw PluginMarketManagerError.commandFailed(error.localizedDescription)
        }
        guard result.status == 0 else {
            let detail = (result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? result.stdout
                : result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let bounded = detail.count > 1200 ? String(detail.suffix(1200)) : detail
            throw PluginMarketManagerError.commandFailed(
                bounded.isEmpty ? "退出状态 \(result.status)" : bounded
            )
        }
    }

    private func restartRuntimeAndWait() async throws {
        runtime.start()
        try await waitForRuntimeReady()
    }

    private func waitForRuntimeReady(timeout: TimeInterval = 120) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch runtime.state {
            case .ready:
                return
            case .failed, .crashed:
                throw PluginMarketManagerError.unavailable(
                    runtime.lastError?.localizedDescription ?? "Runtime 重启失败"
                )
            default:
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw PluginMarketManagerError.unavailable("Runtime 重启超时")
    }

    private enum StatusErrorUpdate {
        case keep
        case set(String?)
    }

    private func stateCopy(
        busy: Bool? = nil,
        statusError: StatusErrorUpdate = .keep,
        lastOperation: PluginMarketOperationRecord? = nil
    ) -> PluginMarketState {
        let nextStatusError: String?
        switch statusError {
        case .keep:
            nextStatusError = state.statusError
        case .set(let value):
            nextStatusError = value
        }
        return PluginMarketState(
            installState: state.installState,
            packageName: state.packageName,
            requestedVersion: state.requestedVersion,
            installedVersion: state.installedVersion,
            latestVersion: state.latestVersion,
            updateAvailable: state.updateAvailable,
            compatibleHarness: state.compatibleHarness,
            enabled: state.enabled,
            routeAvailable: state.routeAvailable,
            busy: busy ?? state.busy,
            profileName: state.profileName,
            profileDirectory: state.profileDirectory,
            source: state.source,
            integrity: state.integrity,
            statusError: nextStatusError,
            lastOperation: lastOperation ?? state.lastOperation
        )
    }

    private func persist(_ record: PluginMarketOperationRecord) {
        guard let operationRecordURL else { return }
        do {
            try fileManager.createDirectory(
                at: operationRecordURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(record)
            try data.write(to: operationRecordURL, options: .atomic)
        } catch {
            runtime.logs.log(
                component: "PluginMarket",
                level: "warn",
                message: "unable to persist operation result: \(error.localizedDescription)"
            )
        }
    }

    private static func loadOperationRecord(
        from url: URL?,
        fileManager: FileManager
    ) -> PluginMarketOperationRecord? {
        guard let url,
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PluginMarketOperationRecord.self, from: data)
    }
}
