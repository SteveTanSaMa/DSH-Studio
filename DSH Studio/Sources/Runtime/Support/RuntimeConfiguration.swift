//
//  RuntimeConfiguration.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import Foundation

/// All launch-time values needed to start `dsh web`.
public struct RuntimeConfiguration: Sendable, Equatable {
    public static let loopbackHost = "127.0.0.1"

    public var nodeExecutable: URL
    public var harnessEntry: URL
    /// The Runtime-owned pnpm shim used by Harness profile/plugin commands.
    public var pnpmExecutable: URL?
    public var dshHome: URL
    public var workspace: URL
    public var profileName: String
    public let host: String
    public var port: String
    public var startupTimeout: TimeInterval
    public var gracefulTimeout: TimeInterval
    public var healthCheckTimeout: TimeInterval
    public var environment: [String: String]
    public var expectedNodeVersion: String
    public var expectedHarnessVersion: String

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
        return launchArguments + ["--host", host, "--port", port]
    }
}
