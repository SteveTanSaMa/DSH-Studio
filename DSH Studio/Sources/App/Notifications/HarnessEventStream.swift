//
//  HarnessEventStream.swift
//  DSH Studio
//

import DeepSeekHarness
import Foundation
import OSLog

/// Owns one reconnecting native WebSocket subscription to the Runtime mux stream.
@MainActor
final class HarnessEventStream {
    /// Called for every event decoded from the stream; `nil` stops delivery.
    var onEvent: ((HarnessNotificationEvent) -> Void)?

    private let logger = Logger(subsystem: "SteveTan.DSH-Studio", category: "HarnessEventStream")
    private var streamTask: Task<Void, Never>?
    private var webSocketTask: URLSessionWebSocketTask?
    private var generation = 0

    /// Starts streaming from the Runtime, replacing any previous subscription.
    ///
    /// A non-loopback base URL is ignored, and the subscription reconnects on its own
    /// until ``stop()`` or another ``start(baseURL:)`` cancels it.
    ///
    /// - Parameter baseURL: Ready URL reported by the Runtime.
    func start(baseURL: URL) {
        stop()
        guard HarnessURLPolicy.isAllowedLoopback(baseURL) else { return }
        var components = URLComponents(
            url: HarnessURLPolicy.baseURL(from: baseURL).appendingPathComponent("api/remote.mux"),
            resolvingAgainstBaseURL: false
        )
        components?.scheme = baseURL.scheme?.lowercased() == "https" ? "wss" : "ws"
        guard let endpoint = components?.url else { return }
        generation += 1
        let currentGeneration = generation
        streamTask = Task { [weak self] in
            await self?.run(endpoint: endpoint, generation: currentGeneration)
        }
    }

    /// Cancels the subscription and its socket.
    ///
    /// The generation counter is bumped so a callback already in flight is dropped.
    func stop() {
        generation += 1
        streamTask?.cancel()
        streamTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    private func run(endpoint: URL, generation: Int) async {
        while !Task.isCancelled {
            let socket = URLSession.shared.webSocketTask(with: endpoint)
            webSocketTask = socket
            socket.resume()
            logger.debug("Opening notification WebSocket \(endpoint.absoluteString, privacy: .public)")
            defer {
                socket.cancel(with: .goingAway, reason: nil)
                if webSocketTask === socket {
                    webSocketTask = nil
                }
            }

            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case let .string(text):
                        data = Data(text.utf8)
                    case let .data(value):
                        data = value
                    @unknown default:
                        continue
                    }
                    guard let event = HarnessNotificationEvent(wireData: data) else { continue }
                    guard self.generation == generation else { return }
                    onEvent?(event)
                }
            } catch is CancellationError {
                return
            } catch {
                logger.error("Notification WebSocket failed: \(error.localizedDescription, privacy: .public)")
                guard !Task.isCancelled else { return }
            }

            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}
