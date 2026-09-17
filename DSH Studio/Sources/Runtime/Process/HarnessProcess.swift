//
//  HarnessProcess.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/16.
//

import Darwin
import Foundation

/// A thin abstraction over a Harness child process so tests can fake it.
///
/// ``RuntimeManager`` owns the lifecycle and only talks to this seam, which keeps
/// process handling out of the manager itself.
public protocol HarnessProcess: AnyObject {
    /// Process identifier while the child is running.
    var pid: Int32? { get }
    /// Whether the child process is still running.
    var isRunning: Bool { get }
    /// Receives standard-output chunks; called on an arbitrary queue.
    var onOutput: ((Data) -> Void)? { get set }
    /// Receives standard-error chunks; called on an arbitrary queue.
    var onError: ((Data) -> Void)? { get set }
    /// Called once with the exit status when the child terminates.
    var onTermination: ((Int32) -> Void)? { get set }
    /// Starts the child process.
    ///
    /// - Throws: ``RuntimeError/processLaunchFailed(_:)`` when the executable cannot
    ///   be started.
    func launch() throws
    /// Asks the child to exit and lets the runtime time the shutdown.
    func terminateGracefully()
    /// Kills the child immediately when a graceful exit did not happen.
    func forceTerminate()
}

/// Creates the process used to launch Harness.
public protocol HarnessProcessFactory {
    /// Builds a child process and attaches RuntimeManager callbacks.
    func makeProcess(
        configuration: RuntimeConfiguration,
        onOutput: @escaping (Data) -> Void,
        onError: @escaping (Data) -> Void,
        onTermination: @escaping (Int32) -> Void
    ) -> HarnessProcess
}

/// Production process backed by Foundation's `Process`.
public final class SystemHarnessProcess: HarnessProcess {
    private let process = Process()
    private let configuration: RuntimeConfiguration

    /// Process identifier, or `nil` once the child has exited.
    public var pid: Int32? {
        process.isRunning ? process.processIdentifier : nil
    }

    /// Whether the underlying process is still running.
    public var isRunning: Bool {
        process.isRunning
    }

    /// Receives standard-output chunks from the child.
    public var onOutput: ((Data) -> Void)?
    /// Receives standard-error chunks from the child.
    public var onError: ((Data) -> Void)?
    /// Called once with the exit status when the child terminates.
    public var onTermination: ((Int32) -> Void)?

    /// Creates a process for one launch configuration.
    ///
    /// - Parameter configuration: Launch-time values used by ``launch()``.
    public init(configuration: RuntimeConfiguration) {
        self.configuration = configuration
    }

    /// Starts Harness with the configured arguments and environment.
    ///
    /// Only app-owned Runtime variables are overlaid on the inherited environment;
    /// user credentials are never injected here.
    ///
    /// - Throws: ``RuntimeError/processLaunchFailed(_:)`` when the executable cannot
    ///   be started.
    public func launch() throws {
        // Copy the base environment, then overlay only app-owned Runtime
        // variables. User API keys are never injected by this layer.
        process.executableURL = configuration.nodeExecutable
        process.arguments = configuration.arguments
        process.currentDirectoryURL = configuration.workspace

        var environment = ProcessInfo.processInfo.environment
        environment["DSH_HOME"] = configuration.dshHome.path
        environment["DSH_TELEMETRY_DISABLED"] = "1"
        environment["NARB_DISABLE_NATIVE_CACHE"] = "1"
        for (key, value) in configuration.environment {
            environment[key] = value
        }
        // Apply the Runtime path after configuration overrides so a caller
        // cannot accidentally hide the bundled pnpm shim with a custom PATH.
        environment["PATH"] = Self.runtimePath(
            nodeExecutable: configuration.nodeExecutable,
            pnpmExecutable: configuration.pnpmExecutable,
            inheritedPath: environment["PATH"]
        )
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Pipe callbacks arrive in arbitrary chunks; RuntimeManager performs
        // line buffering and process-generation checks at the next boundary.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.onOutput?(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self?.onError?(data)
            }
        }

        process.terminationHandler = { [weak self] process in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            self?.onTermination?(process.terminationStatus)
        }

        try process.run()
    }

    /// Sends `SIGTERM` and lets the runtime wait for the graceful timeout.
    public func terminateGracefully() {
        guard process.isRunning else { return }
        process.terminate()
    }

    /// Sends `SIGKILL` when a graceful exit did not happen.
    public func forceTerminate() {
        let identifier = process.processIdentifier
        guard identifier > 0 else { return }
        kill(identifier, SIGKILL)
    }

    /// Returns the child-process PATH with Runtime-owned tools first.
    ///
    /// Harness invokes pnpm by name, so this ordering is part of the Runtime
    /// installation contract rather than a convenience for the shell.
    static func runtimePath(
        nodeExecutable: URL,
        pnpmExecutable: URL?,
        inheritedPath: String?
    ) -> String {
        var entries: [String] = []
        if let pnpmExecutable {
            entries.append(pnpmExecutable.deletingLastPathComponent().path)
        }
        entries.append(nodeExecutable.deletingLastPathComponent().path)
        if let inheritedPath, !inheritedPath.isEmpty {
            entries.append(inheritedPath)
        }
        return entries.joined(separator: ":")
    }
}

/// Creates production child processes backed by Foundation's `Process`.
public final class SystemHarnessProcessFactory: HarnessProcessFactory {
    /// Creates a factory with no shared state.
    public init() {}

    /// Creates a process with the Runtime's output and exit callbacks attached.
    ///
    /// - Parameters:
    ///   - configuration: Launch-time values for the child process.
    ///   - onOutput: Receives standard-output chunks.
    ///   - onError: Receives standard-error chunks.
    ///   - onTermination: Receives the exit status once.
    /// - Returns: A process that has not been started yet.
    public func makeProcess(
        configuration: RuntimeConfiguration,
        onOutput: @escaping (Data) -> Void,
        onError: @escaping (Data) -> Void,
        onTermination: @escaping (Int32) -> Void
    ) -> HarnessProcess {
        let process = SystemHarnessProcess(configuration: configuration)
        process.onOutput = onOutput
        process.onError = onError
        process.onTermination = onTermination
        return process
    }
}
