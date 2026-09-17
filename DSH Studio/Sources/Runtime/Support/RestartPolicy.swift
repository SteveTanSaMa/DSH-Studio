//
//  RestartPolicy.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import Foundation

/// Conservative automatic restart policy for unexpected Harness crashes.
public struct RestartPolicy: Equatable, Sendable {
    /// Whether automatic restarts are allowed at all.
    public var enabled: Bool
    /// Maximum number of restarts inside one crash cycle.
    public var maxAttempts: Int
    /// Delay before each restart, indexed by one-based attempt number.
    public var delays: [TimeInterval]

    /// Creates a restart policy.
    ///
    /// - Parameters:
    ///   - enabled: Whether restarts are allowed; defaults to `true`.
    ///   - maxAttempts: Restart limit per crash cycle; defaults to 3.
    ///   - delays: Backoff seconds per attempt; defaults to 1, 2, and 4 seconds.
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

/// Tracks one crash and restart cycle for the supervisor.
public final class RestartTracker {
    /// Crashes recorded since the last ``reset()``.
    public private(set) var attempts = 0
    /// When the most recent crash was recorded.
    public private(set) var lastCrashDate: Date?

    /// Creates an empty tracker.
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
