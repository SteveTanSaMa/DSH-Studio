//
//  RuntimeManager.swift
//  DSH Studio
//

import Combine
import Darwin
import Foundation
import DeepSeekHarness
import DeepSeekLogging

/// Owns the Harness child process and its lifecycle state machine.
@MainActor
public final class RuntimeManager: ObservableObject {
    @Published public internal(set) var state: RuntimeState = .idle
    @Published public internal(set) var readyURL: URL?
    @Published public internal(set) var lastError: RuntimeError?
    @Published public internal(set) var nodeVersion: String?
    @Published public internal(set) var harnessVersion: String?
    @Published public internal(set) var runtimeVersionStatus: RuntimeVersionStatus?
    @Published public internal(set) var activeDataProfile: RuntimeDataProfile?
    @Published public internal(set) var restartCount = 0
    public internal(set) var lastTerminationStatus: Int32?

    public internal(set) var configuration: RuntimeConfiguration
    /// Bounded in-memory history plus the sanitized log file shared with the app.
    public let logs: RuntimeLogStore
    /// Policy applied when the child process exits unexpectedly.
    public var restartPolicy: RestartPolicy
    /// Store used to persist data-profile metadata, when one is configured.
    public let dataProfileStore: RuntimeDataProfileStore?

    /// Creates the child process; injected so tests can run without launching one.
    let processFactory: HarnessProcessFactory
    /// Probes the ready URL after the process reports it.
    let healthChecker: HarnessHealthChecking
    /// Installs a missing Runtime; `nil` when this manager may not provision.
    let provisioner: (any RuntimeProvisioning)?
    /// Checks, prepares, and activates Runtime updates; `nil` disables updates.
    let runtimeUpdater: (any RuntimeUpdating)?
    /// Whether the installation is validated before every launch.
    let validateRuntimeOnStart: Bool
    /// Counts recent restarts so an unstable Runtime stops being retried.
    let restartTracker = RestartTracker()
    /// The child process while one is owned by this manager.
    var process: HarnessProcess?
    /// Downloaded update artifact that has not been activated yet.
    var stagedURL: URL?
    /// Pending launch or provisioning work for the current generation.
    var startupTask: Task<Void, Never>?
    /// Graceful-shutdown work; cancelled when a new launch supersedes it.
    var stopTask: Task<Void, Never>?
    /// One-shot installation work started when the Runtime is missing or invalid.
    var provisioningTask: Task<Void, Never>?
    /// Delayed restart scheduled by the restart policy.
    var restartTask: Task<Void, Never>?
    /// Incremented per launch so callbacks from a superseded process are ignored.
    var processGeneration = 0
    /// Set when a stop was requested, so the exit is not reported as a crash.
    var stopRequested = false
    /// Set once the child exit has been handled for the current generation.
    var processExited = false
    /// Partial standard-output line kept until its newline arrives.
    var stdoutBuffer = ""
    /// Partial standard-error line kept until its newline arrives.
    var stderrBuffer = ""
    /// Most recent standard-error lines, surfaced in crash diagnostics.
    var lastStderrLines: [String] = []
    /// Whether the data home was empty at launch, used to stamp a format on first run.
    var dataHomeWasEmptyBeforeLaunch: Bool?
    /// Matches the `dsh web: http://127.0.0.1:<port>` line that signals readiness.
    let readyPattern = try! NSRegularExpression(
        pattern: #"dsh web: (http://127\.0\.0\.1:\d+(?:/[^\s]*)?)"#
    )

    /// Coordinator for update checks and activation; `nil` without an updater.
    ///
    /// Created lazily so a manager without update support never allocates one.
    public lazy var runtimeUpdateCoordinator: RuntimeUpdateCoordinator? = {
        guard let runtimeUpdater else { return nil }
        return RuntimeUpdateCoordinator(runtime: self, updater: runtimeUpdater)
    }()

    /// Creates a manager for one Runtime configuration.
    ///
    /// Versions and the version status are read during initialization, so a caller
    /// can inspect the installation before starting anything.
    ///
    /// - Parameters:
    ///   - configuration: Launch-time values for the child process.
    ///   - processFactory: Process seam; defaults to the system implementation.
    ///   - healthChecker: Health probe used after the ready line appears.
    ///   - logFileURL: File that receives log entries; `nil` keeps logs in memory.
    ///   - restartPolicy: Policy for unexpected exits.
    ///   - validateRuntimeOnStart: Whether to validate the installation before launch.
    ///   - provisioner: Installer used when the Runtime is missing or invalid.
    ///   - updater: Update source; falls back to the provisioner when it can update.
    ///   - dataProfileStore: Store used to persist data-profile metadata.
    public init(
        configuration: RuntimeConfiguration,
        processFactory: HarnessProcessFactory = SystemHarnessProcessFactory(),
        healthChecker: HarnessHealthChecking = SystemHarnessHealthChecker(),
        logFileURL: URL? = nil,
        restartPolicy: RestartPolicy = RestartPolicy(),
        validateRuntimeOnStart: Bool = true,
        provisioner: (any RuntimeProvisioning)? = nil,
        updater: (any RuntimeUpdating)? = nil,
        dataProfileStore: RuntimeDataProfileStore? = nil
    ) {
        self.configuration = configuration
        self.processFactory = processFactory
        self.healthChecker = healthChecker
        self.provisioner = provisioner
        self.runtimeUpdater = updater ?? (provisioner as? any RuntimeUpdating)
        self.restartPolicy = restartPolicy
        self.validateRuntimeOnStart = validateRuntimeOnStart
        self.logs = RuntimeLogStore(logFileURL: logFileURL)
        self.dataProfileStore = dataProfileStore
        self.activeDataProfile = nil
        self.lastTerminationStatus = nil
        self.nodeVersion = RuntimeLocator.nodeVersion(nodeExecutable: configuration.nodeExecutable)
        self.harnessVersion = RuntimeLocator.packageJSONVersion(at: configuration.harnessEntry)
        self.runtimeVersionStatus = self.runtimeUpdater?.versionStatus()
        adoptInstalledRuntimeIfAvailable()
        loadSelectedDataProfile()
        refreshRuntimeMetadata()
    }

    /// Starts the Runtime, provisioning or adopting an installation first.
    ///
    /// The call is ignored while another lifecycle operation is running, and a
    /// missing or invalid installation is provisioned before the first launch.
    public func start() {
        guard state == .idle || state == .failed || state == .crashed || state == .terminated else {
            return
        }
        restartTask?.cancel()
        restartTask = nil
        lastError = nil
        readyURL = nil
        stopRequested = false
        processExited = false
        stdoutBuffer = ""
        stderrBuffer = ""
        dataHomeWasEmptyBeforeLaunch = nil
        lastTerminationStatus = nil

        if let runtimeUpdater {
            let status = runtimeUpdater.versionStatus()
            runtimeVersionStatus = status
            if status.kind == .missing || status.kind == .invalid {
                beginProvisioning(with: runtimeUpdater)
                return
            }
            adoptInstalledRuntimeIfAvailable()
            loadSelectedDataProfile()
        } else if let provisioner,
                  !RuntimeLocator.isComplete(
                      root: provisioner.root,
                      architecture: provisioner.architecture
                  ) {
            beginProvisioning(with: provisioner)
            return
        }
        beginLaunch()
    }

    /// Process identifier of the running child, or `nil` when none is running.
    public var currentProcessID: Int32? {
        process?.pid
    }

    /// Whether the DSH terminal can be opened right now.
    ///
    /// False during provisioning, updates, rollbacks, and launch or shutdown
    /// transitions, when the Runtime's paths are not stable enough to shell into.
    public var canOpenTerminal: Bool {
        state != .provisioning
            && state != .updating
            && state != .rollingBack
            && state != .launching
            && state != .starting
            && state != .stopping
    }

    /// Generation counter of the current process, used to discard stale callbacks.
    public var currentProcessGeneration: Int {
        processGeneration
    }

    /// Standard-error lines from the most recent child, for crash diagnostics.
    public var recentCrashStderr: [String] {
        lastStderrLines
    }

    private func beginProvisioning(with provisioner: any RuntimeProvisioning) {
        state = .provisioning
        logs.log(component: "Runtime", level: "info", message: "preparing online Runtime")
        provisioningTask?.cancel()
        provisioningTask = Task.detached { [weak self, provisioner] in
            do {
                let result = try await provisioner.provision()
                guard !Task.isCancelled else { return }
                await self?.finishProvisioning(result)
            } catch is CancellationError {
                return
            } catch {
                await self?.failProvisioning(error)
            }
        }
    }

    private func finishProvisioning(_ result: RuntimeProvisioningResult) {
        guard state == .provisioning else { return }
        applyRuntimeResult(result)
        loadSelectedDataProfile()
        provisioningTask = nil
        beginLaunch()
    }

    private func failProvisioning(_ error: Error) {
        guard state == .provisioning else { return }
        provisioningTask = nil
        fail(.runtimeProvisioningFailed(error.localizedDescription))
    }

    private func beginLaunch() {
        state = .launching
        processGeneration += 1
        let generation = processGeneration
        dataHomeWasEmptyBeforeLaunch = dataProfileStore?.isDataHomeEmpty(configuration.dshHome)

        logs.log(component: "App", level: "info", message: "app launch")
        logs.log(component: "Runtime", level: "info", message: "node path \(configuration.nodeExecutable.path)")
        logs.log(component: "Runtime", level: "info", message: "node version \(nodeVersion ?? "unknown")")
        logs.log(component: "Runtime", level: "info", message: "harness version \(harnessVersion ?? "unknown")")

        if validateRuntimeOnStart {
            guard validateRuntime() else { return }
        }
        guard validateDataProfileForCurrentRuntime() else { return }
        guard prepareDirectories() else { return }
        cleanStaleProcessIfNeeded()

        let process = processFactory.makeProcess(
            configuration: configuration,
            onOutput: { [weak self] data in
                Task { @MainActor [weak self] in
                    self?.handleStdout(data, generation: generation)
                }
            },
            onError: { [weak self] data in
                Task { @MainActor [weak self] in
                    self?.handleStderr(data, generation: generation)
                }
            },
            onTermination: { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.handleTermination(status, generation: generation)
                }
            }
        )
        self.process = process

        do {
            try process.launch()
        } catch {
            self.process = nil
            fail(.processLaunchFailed(error.localizedDescription))
            return
        }

        logs.log(component: "Runtime", level: "info", message: "process launch pid \(process.pid.map(String.init) ?? "unknown")")
        if let pid = process.pid {
            let pidURL = configuration.dshHome
                .deletingLastPathComponent()
                .appendingPathComponent("runtime.pid")
            try? String(pid).data(using: .utf8)?.write(to: pidURL)
        }
        state = .starting
        armStartupTimeout(generation: generation)
    }

    /// Moves the manager into the failed state and records why.
    ///
    /// Pending startup work is cancelled and a running child is force-terminated, so
    /// a failure cannot leave a half-started process behind.
    ///
    /// - Parameter error: Failure to publish through ``lastError``.
    func fail(_ error: RuntimeError) {
        startupTask?.cancel()
        startupTask = nil
        lastError = error
        logs.log(component: "Runtime", level: "error", message: error.localizedDescription)
        if let process, process.isRunning {
            process.forceTerminate()
        }
        state = .failed
    }
}
