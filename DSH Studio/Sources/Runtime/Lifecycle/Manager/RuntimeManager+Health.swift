//
//  RuntimeManager+Health.swift
//  DSH Studio
//

import Foundation

extension RuntimeManager {
    func performHealthCheck(url: URL, generation: Int) async {
        guard state == .starting, generation == processGeneration else { return }
        logs.log(component: "Harness", level: "info", message: "detected port \(url.port.map(String.init) ?? "unknown")")
        logs.log(component: "Harness", level: "info", message: "health check \(url.appendingPathComponent("api/host.describe").absoluteString)")
        // A late response from an old process must not mark its replacement
        // ready, so the generation is checked again after this await.
        let healthy = await healthChecker.check(
            baseURL: url,
            timeout: configuration.healthCheckTimeout
        )
        guard state == .starting, generation == processGeneration else { return }
        if healthy {
            startupTask?.cancel()
            startupTask = nil
            restartTracker.reset()
            restartCount = 0
            readyURL = url
            state = .ready
            guard activateSelectedDataProfileIfPossible() else {
                fail(.runtimeProvisioningFailed("无法保存 Runtime 数据环境状态"))
                return
            }
            logs.log(component: "Harness", level: "info", message: "health check ok")
            logs.log(component: "Runtime", level: "info", message: "state ready")
        } else {
            fail(.healthCheckFailed)
        }
    }

    func handleTermination(_ status: Int32, generation: Int) {
        guard generation == processGeneration else { return }
        processExited = true
        process = nil
        logs.log(component: "Runtime", level: "info", message: "runtime termination status \(status)")
        if state == .failed { return }
        if stopRequested {
            state = .terminated
            return
        }
        startupTask?.cancel()
        startupTask = nil
        let shouldRestart = state == .ready || state == .starting || state == .launching
        state = shouldRestart ? .crashed : .failed
        lastError = .processCrashed(exitStatus: status, stderr: lastStderrLines)
        if shouldRestart {
            scheduleRestart()
        }
    }

    private func scheduleRestart() {
        guard restartPolicy.enabled else { return }
        let attempt = restartTracker.recordCrash()
        guard let delay = restartPolicy.delay(forAttempt: attempt) else {
            restartCount = restartTracker.attempts
            state = .failed
            logs.log(component: "Runtime", level: "error", message: "restart limit reached")
            return
        }
        restartCount = attempt
        logs.log(component: "Runtime", level: "warn", message: "scheduling restart in \(delay)s (attempt \(attempt))")
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled,
                  let self,
                  self.state == .crashed else { return }
            self.restartTask = nil
            self.start()
        }
    }

    func armStartupTimeout(generation: Int) {
        let timeout = configuration.startupTimeout
        startupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self,
                  self.processGeneration == generation,
                  self.state == .starting || self.state == .launching else { return }
            self.fail(.readyTimeout(timeout))
        }
    }

}
