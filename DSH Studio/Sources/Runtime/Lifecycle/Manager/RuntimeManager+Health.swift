//
//  RuntimeManager+Health.swift
//  DSH Studio
//

import Foundation
import DeepSeekHarness

/// Readiness probing, exit handling, and the startup deadline.
extension RuntimeManager {
    /// Probes the freshly launched child and promotes it to ready when healthy.
    ///
    /// The generation is re-checked after the await, so a late answer from a replaced
    /// process can never mark its successor ready.
    ///
    /// - Parameters:
    ///   - url: URL the child printed as its ready line.
    ///   - generation: Process generation the probe belongs to.
    func performHealthCheck(url: URL, generation: Int) async {
        guard state == .starting, generation == processGeneration else { return }
        logs.log(component: "Harness", level: "info", message: "detected port \(url.port.map(String.init) ?? "unknown")")
        let cleanBaseURL = HarnessURLPolicy.baseURL(from: url)
        logs.log(
            component: "Harness",
            level: "info",
            message: "health check \(cleanBaseURL.appendingPathComponent("api/settings/describe").absoluteString)"
        )
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

    /// Records the child's exit and decides between a crash and a clean stop.
    ///
    /// A requested stop ends in terminated; an unexpected exit while ready, starting,
    /// or launching becomes a crash so the restart policy can act on it.
    ///
    /// - Parameters:
    ///   - status: Exit status reported by the child.
    ///   - generation: Process generation that exited.
    func handleTermination(_ status: Int32, generation: Int) {
        guard generation == processGeneration else { return }
        processExited = true
        lastTerminationStatus = status
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

    /// Fails the launch if the child does not become ready in time.
    ///
    /// - Parameter generation: Process generation the deadline belongs to.
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
