//
//  RuntimeConfiguration.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import Foundation

/// All launch-time values needed to start `dsh web`.
public struct RuntimeConfiguration: Sendable, Equatable {
    /// The only host Harness is ever bound to.
    public static let loopbackHost = "127.0.0.1"

    /// Node.js binary used to launch Harness.
    public var nodeExecutable: URL
    /// Harness CLI entry point executed by Node.js.
    public var harnessEntry: URL
    /// The Runtime-owned pnpm shim used by Harness profile/plugin commands.
    public var pnpmExecutable: URL?
    /// Harness data home exported to the child process.
    public var dshHome: URL
    /// Workspace directory Harness starts in.
    public var workspace: URL
    /// Harness profile the child process launches with.
    public var profileName: String
    /// Bind host; always ``loopbackHost`` and never caller-supplied.
    public let host: String
    /// Requested TCP port; `0` lets the operating system pick a free one.
    public var port: String
    /// Seconds to wait for the ready line before the launch is failed.
    public var startupTimeout: TimeInterval
    /// Seconds a graceful shutdown may take before the process is killed.
    public var gracefulTimeout: TimeInterval
    /// Seconds allowed for one HTTP health-check request.
    public var healthCheckTimeout: TimeInterval
    /// Extra environment variables merged into the child process.
    public var environment: [String: String]
    /// Node.js version the Runtime must report at launch.
    public var expectedNodeVersion: String
    /// Harness version the Runtime must report at launch.
    public var expectedHarnessVersion: String

    /// Creates a launch configuration.
    ///
    /// The bind host is fixed to loopback and is not a parameter, so no caller can
    /// expose Harness beyond this machine.
    ///
    /// - Parameters:
    ///   - nodeExecutable: Node.js binary that runs Harness.
    ///   - harnessEntry: Harness CLI entry point.
    ///   - dshHome: Harness data home for the child process.
    ///   - workspace: Workspace directory Harness starts in.
    ///   - pnpmExecutable: Runtime-owned pnpm shim, when the Runtime provides one.
    ///   - port: TCP port, `0` to let the system choose.
    ///   - startupTimeout: Seconds to wait for readiness.
    ///   - gracefulTimeout: Seconds allowed for a graceful shutdown.
    ///   - healthCheckTimeout: Seconds allowed per health check.
    ///   - environment: Extra environment variables for the child process.
    ///   - expectedNodeVersion: Node.js version required at launch.
    ///   - expectedHarnessVersion: Harness version required at launch.
    ///   - profileName: Harness profile to launch.
    public init(
        nodeExecutable: URL,
        harnessEntry: URL,
        dshHome: URL,
        workspace: URL,
        pnpmExecutable: URL? = nil,
        port: String = "0",
        startupTimeout: TimeInterval = 90,
        gracefulTimeout: TimeInterval = 6,
        healthCheckTimeout: TimeInterval = 5,
        environment: [String: String] = [:],
        expectedNodeVersion: String = "24.19.0",
        expectedHarnessVersion: String = RuntimeLocator.harnessVersion,
        profileName: String = "web"
    ) {
        self.nodeExecutable = nodeExecutable
        self.harnessEntry = harnessEntry
        self.pnpmExecutable = pnpmExecutable
        self.dshHome = dshHome
        self.workspace = workspace
        self.profileName = profileName
        self.host = Self.loopbackHost
        self.port = port
        self.startupTimeout = startupTimeout
        self.gracefulTimeout = gracefulTimeout
        self.healthCheckTimeout = healthCheckTimeout
        self.environment = environment
        self.expectedNodeVersion = expectedNodeVersion
        self.expectedHarnessVersion = expectedHarnessVersion
    }

    /// Arguments passed to the local `dsh web` entry point.
    ///
    /// The explicit loopback bind is part of the security contract: the app
    /// never exposes Harness to the local network.
    public var arguments: [String] {
        let launchArguments: [String]
        if profileName == "web" {
            launchArguments = [harnessEntry.path, "web"]
        } else {
            launchArguments = [harnessEntry.path, "--profile", profileName]
        }
        // DSH Studio owns the WebView, so the Runtime must never launch the
        // user's default browser while starting its local server.
        return launchArguments + ["--no-open", "--host", host, "--port", port]
    }
}
