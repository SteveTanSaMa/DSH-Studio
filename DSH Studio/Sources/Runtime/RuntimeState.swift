//
//  RuntimeState.swift
//  DSH Studio
//
//  Created by Steve Tan on 2026/8/19.
//

import Foundation

/// Explicit lifecycle state of the Harness runtime process.
public enum RuntimeState: Equatable, Sendable {
    case idle
    case provisioning
    case launching
    case starting
    case ready
    case failed
    case stopping
    case terminated
    case crashed
}
