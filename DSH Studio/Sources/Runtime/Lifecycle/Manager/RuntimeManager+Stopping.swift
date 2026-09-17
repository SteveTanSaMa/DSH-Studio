//
//  RuntimeManager+Stopping.swift
//  DSH Studio
//

import Foundation

/// Intentional shutdown and process control for the Harness child.
extension RuntimeManager {
    /// Restarts the app-owned Harness process without entering the crash path.
    ///
    /// Only call this for an intentional restart; an unexpected exit is handled by
    /// the restart policy instead.
    @discardableResult
    public func restart() async -> Bool {
        guard state == .ready else { return false }
        await stop()
        guard state == .terminated || state == .idle else { return false }
        start()
        return true
    }

    /// Stops the Harness child, escalating when it does not exit in time.
    ///
    /// The call is a no-op once the Runtime is already stopped, and concurrent
    /// callers await the same shutdown task instead of starting a second one.
    /// Stopping during provisioning cancels that work and marks the Runtime
    /// terminated without launching a process.
    public func stop() async {
        if state == .terminated || state == .idle {
            return
        }
        if state == .provisioning {
            stopRequested = true
            restartTask?.cancel()
            restartTask = nil
            provisioningTask?.cancel()
            provisioningTask = nil
            readyURL = nil
            state = .terminated
            return
        }
        if let stopTask {
            await stopTask.value
            return
        }
        let task = Task { [weak self] in
            _ = await self?.performStop()
        }
        stopTask = task
        await task.value
    }

    /// Stops immediately, without waiting for a graceful exit.
    ///
    /// Pending startup, provisioning, and restart work is cancelled and the child is
    /// killed, which is the path used when the app must not block on shutdown.
    public func forceStop() {
        guard state != .terminated else { return }
        stopRequested = true
        restartTask?.cancel()
        restartTask = nil
        startupTask?.cancel()
        startupTask = nil
        provisioningTask?.cancel()
        provisioningTask = nil
        process?.forceTerminate()
        process = nil
        processExited = true
        readyURL = nil
        state = .terminated
        removePIDFile()
    }

    private func performStop() async {
        defer { stopTask = nil }
        stopRequested = true
        restartTask?.cancel()
        restartTask = nil
        startupTask?.cancel()
        startupTask = nil
        guard let process, state != .terminated else {
            state = .terminated
            self.process = nil
            processExited = true
            readyURL = nil
            removePIDFile()
            return
        }
        state = .stopping
        logs.log(component: "Runtime", level: "info", message: "sending SIGTERM")
        process.terminateGracefully()

        let timeout = UInt64(configuration.gracefulTimeout * 1_000_000_000)
        try? await Task.sleep(nanoseconds: timeout)

        if !processExited {
            logs.log(component: "Runtime", level: "warn", message: "graceful timeout, forcing terminate")
            process.forceTerminate()
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        state = .terminated
        self.process = nil
        removePIDFile()
    }
}
