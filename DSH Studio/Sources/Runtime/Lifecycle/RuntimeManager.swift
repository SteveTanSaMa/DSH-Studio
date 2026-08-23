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

    public internal(set) var configuration: RuntimeConfiguration
    public let logs: RuntimeLogStore
    public var restartPolicy: RestartPolicy
    public let dataProfileStore: RuntimeDataProfileStore?

    let processFactory: HarnessProcessFactory
    let healthChecker: HarnessHealthChecking
    let provisioner: (any RuntimeProvisioning)?
    let runtimeUpdater: (any RuntimeUpdating)?
    let validateRuntimeOnStart: Bool
    let restartTracker = RestartTracker()
    var process: HarnessProcess?
    var stagedURL: URL?
    var startupTask: Task<Void, Never>?
    var stopTask: Task<Void, Never>?
    var provisioningTask: Task<Void, Never>?
    var restartTask: Task<Void, Never>?
    var processGeneration = 0
    var stopRequested = false
    var processExited = false
    var stdoutBuffer = ""
    var stderrBuffer = ""
    var lastStderrLines: [String] = []
    var dataHomeWasEmptyBeforeLaunch: Bool?
    let readyPattern = try! NSRegularExpression(
        pattern: #"dsh web: (http://127\.0\.0\.1:\d+)"#
    )

    public lazy var runtimeUpdateCoordinator: RuntimeUpdateCoordinator? = {
        guard let runtimeUpdater else { return nil }
        return RuntimeUpdateCoordinator(runtime: self, updater: runtimeUpdater)
    }()

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
        self.nodeVersion = RuntimeLocator.nodeVersion(nodeExecutable: configuration.nodeExecutable)
        self.harnessVersion = RuntimeLocator.packageJSONVersion(at: configuration.harnessEntry)
        self.runtimeVersionStatus = self.runtimeUpdater?.versionStatus()
        adoptInstalledRuntimeIfAvailable()
        loadSelectedDataProfile()
        refreshRuntimeMetadata()
    }

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
