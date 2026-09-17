//
//  HarnessWebBridgeScripts.swift
//  DSH Studio
//

import Foundation

/// Small presentation-only DOM adjustments owned by the macOS shell.
public enum HarnessLayoutWebBridge {
    /// The complete layout script injected into the Harness page.
    ///
    /// Composed from the bootstrap part and the behavior part so each half stays
    /// readable.
    public static let source = sourcePartOne + sourcePartTwo
}
