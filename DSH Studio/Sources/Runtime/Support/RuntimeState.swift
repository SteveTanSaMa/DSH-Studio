//
//  RuntimeState.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/20.
//

import Foundation

/// Explicit lifecycle state of the Harness runtime process.
///
/// The manager publishes exactly one state at a time; long-running states
/// (``provisioning``, ``updating``, ``rollingBack``, ``launching``, ``starting``,
/// ``stopping``) are the ones callers must treat as busy.
public enum RuntimeState: Equatable, Sendable {
    /// No process is running and nothing is scheduled.
    case idle
    /// A Runtime installation is being downloaded and verified.
    case provisioning
    /// A verified update is being activated.
    case updating
    /// The previous Runtime build is being restored.
    case rollingBack
    /// The child process has been created but has not been started.
    case launching
    /// The child is running and the ready line is still awaited.
    case starting
    /// The Harness server answered and the WebView may attach.
    case ready
    /// Startup or provisioning failed; see ``RuntimeManager/lastError``.
    case failed
    /// A graceful shutdown is in flight.
    case stopping
    /// The child exited after an intentional stop.
    case terminated
    /// The child exited unexpectedly and may be restarted by policy.
    case crashed
}
