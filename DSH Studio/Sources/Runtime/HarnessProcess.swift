//
//  HarnessProcess.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/16.
//

import Darwin
import Foundation

/// A thin abstraction over a Harness child process so tests can fake it.
public protocol HarnessProcess: AnyObject {
    var pid: Int32? { get }
    var isRunning: Bool { get }
    var onOutput: ((Data) -> Void)? { get set }
    var onError: ((Data) -> Void)? { get set }
    var onTermination: ((Int32) -> Void)? { get set }
    func launch() throws
    func terminateGracefully()
    func forceTerminate()
}

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

    public var pid: Int32? {
        process.isRunning ? process.processIdentifier : nil
    }

    public var isRunning: Bool {
        process.isRunning
    }

    public var onOutput: ((Data) -> Void)?
    public var onError: ((Data) -> Void)?
    public var onTermination: ((Int32) -> Void)?

    public init(configuration: RuntimeConfiguration) {
        self.configuration = configuration
    }

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

    public func terminateGracefully() {
        guard process.isRunning else { return }
        process.terminate()
    }

    public func forceTerminate() {
        let identifier = process.processIdentifier
        guard identifier > 0 else { return }
        kill(identifier, SIGKILL)
    }
}

public final class SystemHarnessProcessFactory: HarnessProcessFactory {
    public init() {}

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
