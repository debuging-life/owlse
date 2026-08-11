// The MIT License (MIT)
//
// Copyright (c) 2020-2026 Alexander Grebenyuk (github.com/kean).

import Foundation
import Owlse

// WebSocket frames can't be captured by swizzling the way URLSession requests
// are: `URLSessionWebSocketTask.Message` is a Swift-only enum with no
// Objective-C representation. So instead of `NetworkLogger.enableProxy()`
// doing it for you, you create the socket through `OwlseWebSocketTask` and
// every frame is recorded.
//
// This is a complete, realistic service. The only Owlse-specific line is the
// one that creates the task — everything else is how you'd write it anyway.

/// A chat socket that connects, subscribes to a room, streams messages, and
/// keeps itself alive with pings. Every frame it sends or receives shows up in
/// the desktop app's **Sockets** tab, grouped by URL.
final class ChatSocketService {
    /// Hold on to the task. Nothing else retains it, and once it deallocates
    /// you stop receiving — which looks exactly like "Owlse stopped logging".
    private var socket: OwlseWebSocketTask?
    private var pingTimer: Timer?
    private let url: URL

    /// Called for every decoded server message.
    var onMessage: ((String) -> Void)?

    init(url: URL) {
        self.url = url
    }

    // MARK: Connecting

    func connect() {
        // ── The one line that makes this visible in Owlse ──────────────
        // Was: let task = URLSession.shared.webSocketTask(with: url)
        let socket = OwlseWebSocketTask(url: url)
        self.socket = socket

        socket.resume()   // logs an `open` frame
        receiveNext()     // start the receive loop *before* sending anything
        startPinging()

        send(#"{"type":"subscribe","room":"general"}"#)
    }

    func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        // Logs a `close` frame with the code and reason
        socket?.cancel(with: .goingAway, reason: "user left".data(using: .utf8))
        socket = nil
    }

    // MARK: Sending

    func send(_ json: String) {
        socket?.send(.string(json)) { error in
            // The wrapper already logged both the frame and any failure —
            // this is only your own error handling.
            if let error {
                print("send failed: \(error)")
            }
        }
    }

    // MARK: Receiving

    /// `receive` delivers exactly ONE message and then stops. You have to ask
    /// for the next one every time, or the socket goes quiet after a single
    /// frame. This is the single most common reason people think Owlse isn't
    /// tracking their socket — it is, there's just nothing more arriving.
    private func receiveNext() {
        socket?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.onMessage?(text)
                case .data(let data):
                    self.onMessage?(String(decoding: data, as: UTF8.self))
                @unknown default:
                    break
                }
                self.receiveNext()   // ← ask for the next frame

            case .failure:
                // The wrapper logged the error frame. The socket is done;
                // don't loop, or you'll spin on a dead connection.
                self.pingTimer?.invalidate()
            }
        }
    }

    // MARK: Keepalive

    /// Proxies and load balancers drop idle sockets. Each ping and its pong
    /// are logged, so a connection dying quietly is visible on the timeline.
    private func startPinging() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.socket?.sendPing { _ in }
        }
    }
}

// MARK: - The same thing with async/await

/// `OwlseWebSocketTask` mirrors the task's async API too. Note the `for await`
/// style loop: same rule as above, every iteration asks for one more frame.
final class AsyncChatSocketService {
    private let socket: OwlseWebSocketTask

    init(url: URL) {
        socket = OwlseWebSocketTask(url: url)
    }

    func run() async throws {
        socket.resume()
        try await socket.send(.string(#"{"type":"subscribe","room":"general"}"#))

        while !Task.isCancelled {
            let message = try await socket.receive()
            if case .string(let text) = message {
                print("received: \(text)")
            }
        }
        socket.cancel()
    }
}

// MARK: - Using a different socket library

// Not on URLSession? Starscream, SocketRocket, or a server SDK can feed Owlse
// directly — `WebSocketLogger.record` is the same call the wrapper makes
// internally. Report frames in both directions and the Sockets tab can't tell
// the difference.
//
// The `url` you pass is what the desktop app groups connections by, so keep it
// stable for the lifetime of a socket.

final class StarscreamStyleAdapter {
    private let url: String

    init(url: String) {
        self.url = url
    }

    func webSocketDidConnect() {
        WebSocketLogger.record(direction: .received, kind: .open,
                               size: 0, text: "connected", url: url)
    }

    func webSocketDidReceive(text: String) {
        WebSocketLogger.record(direction: .received, kind: .text,
                               size: text.utf8.count, text: text, url: url)
    }

    func webSocketDidSend(text: String) {
        WebSocketLogger.record(direction: .sent, kind: .text,
                               size: text.utf8.count, text: text, url: url)
    }

    func webSocketDidReceive(data: Data) {
        // Binary frames that happen to be UTF-8 JSON are worth decoding —
        // the desktop app pretty-prints anything that parses as JSON.
        let text = String(data: data, encoding: .utf8) ?? "\(data.count) bytes of binary data"
        WebSocketLogger.record(direction: .received, kind: .binary,
                               size: data.count, text: text, url: url)
    }

    func webSocketDidDisconnect(code: Int, reason: String) {
        WebSocketLogger.record(direction: .received, kind: .close,
                               size: 0, text: "closed (code \(code)): \(reason)", url: url)
    }

    func webSocketDidError(_ error: Error) {
        WebSocketLogger.record(direction: .received, kind: .error,
                               size: 0, text: error.localizedDescription, url: url)
    }
}
