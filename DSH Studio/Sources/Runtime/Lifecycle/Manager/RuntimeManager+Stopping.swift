//
//  RuntimeManager+Stopping.swift
//  DSH Studio
//

import Foundation

extension RuntimeManager {
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
