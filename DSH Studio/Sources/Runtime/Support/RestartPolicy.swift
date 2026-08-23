//
//  RestartPolicy.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import Foundation

/// Conservative automatic restart policy for unexpected Harness crashes.
public struct RestartPolicy: Equatable, Sendable {
    public var enabled: Bool
    public var maxAttempts: Int
    public var delays: [TimeInterval]

    public init(
        enabled: Bool = true,
        maxAttempts: Int = 3,
        delays: [TimeInterval] = [1, 2, 4]
    ) {
        self.enabled = enabled
        self.maxAttempts = maxAttempts
        self.delays = delays
    }

    /// Returns the delay for a one-based crash attempt, or nil after the limit.
    public func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt > 0,
              attempt <= maxAttempts,
              attempt <= delays.count else { return nil }
        return delays[attempt - 1]
    }
}

/// Tracks one crash/restart cycle.
public final class RestartTracker {
    public private(set) var attempts = 0
    public private(set) var lastCrashDate: Date?

    public init() {}

    /// Clears the crash budget after a stable Runtime becomes ready.
    public func reset() {
        attempts = 0
        lastCrashDate = nil
    }

    /// Records a crash and returns its one-based attempt number.
    @discardableResult
    public func recordCrash() -> Int {
        attempts += 1
        lastCrashDate = Date()
        return attempts
    }
}
