// The MIT License (MIT)
//
// Copyright (c) 2020-2026 Alexander Grebenyuk (github.com/kean).

import Foundation

/// Captures WebSocket traffic — every frame sent and received, plus opens,
/// closes, and errors — and records it into the store so it streams to the
/// Owlse desktop app alongside regular network requests.
///
/// Create sockets through ``OwlseWebSocketTask`` instead of
/// `URLSessionWebSocketTask` and every frame is logged:
///
/// ```swift
/// let socket = OwlseWebSocketTask(url: url)
/// socket.resume()
/// socket.send(.string("hello")) { _ in }
/// socket.receive { result in … }
/// ```
///
/// - note: Frames are captured by the wrapper rather than by swizzling.
/// `URLSessionWebSocketTask.Message` is a Swift-only enum with no
/// Objective-C representation, so runtime interception would have to reach
/// into private internals and could break with any OS update.
public enum WebSocketLogger {
    /// Frames larger than this are recorded truncated.
    public static var payloadLimit = 8 * 1024

    /// The label every WebSocket log message carries.
    public static let label = "websocket"

    /// Metadata keys on the recorded messages. The desktop app reads these
    /// to build its WebSockets view.
    public enum Key {
        public static let direction = "ws.direction"
        public static let kind = "ws.kind"
        public static let size = "ws.size"
        public static let url = "ws.url"
    }

    public enum Direction: String { case sent, received }
    public enum Kind: String { case text, binary, ping, pong, open, close, error }

    /// Records a frame. Public so apps using a different socket stack
    /// (Starscream, SocketRocket, a server SDK) can feed Owlse too.
    public static func record(
        direction: Direction,
        kind: Kind,
        size: Int,
        text: String,
        url: String,
        store: LoggerStore = .shared
    ) {
        store.storeMessage(
            label: label,
            level: kind == .error ? .error : .debug,
            message: text,
            metadata: [
                Key.direction: .string(direction.rawValue),
                Key.kind: .string(kind.rawValue),
                Key.size: .string("\(size)"),
                Key.url: .string(url)
            ]
        )
    }

    static func describe(_ message: URLSessionWebSocketTask.Message) -> (kind: Kind, size: Int, text: String) {
        switch message {
        case .string(let string):
            return (.text, string.utf8.count, truncate(string))
        case .data(let data):
            // Many protocols send UTF-8 JSON over binary frames — decode when
            // we can, and only fall back to a placeholder for real binary.
            if let text = decodeUTF8(data) {
                return (.binary, data.count, text)
            }
            return (.binary, data.count, "\(data.count) bytes of binary data")
        @unknown default:
            return (.binary, 0, "unsupported frame")
        }
    }

    /// Decodes UTF-8 data, truncating on a character boundary. Returns nil
    /// only when the payload isn't text at all.
    private static func decodeUTF8(_ data: Data) -> String? {
        guard data.count > payloadLimit else {
            return String(data: data, encoding: .utf8)
        }
        // The whole payload must be valid text before we show a prefix of it
        guard String(data: data, encoding: .utf8) != nil else { return nil }
        var end = data.index(data.startIndex, offsetBy: payloadLimit)
        // Walk back off any UTF-8 continuation byte (0b10xxxxxx)
        while end > data.startIndex, data[end] & 0xC0 == 0x80 {
            end = data.index(before: end)
        }
        let kept = data[data.startIndex..<end]
        let text = String(decoding: kept, as: UTF8.self)
        return text + "\n… \(data.count - kept.count) more bytes"
    }

    /// Truncates text on a character boundary, counting UTF-8 bytes so the
    /// limit means what it says for non-ASCII payloads.
    private static func truncate(_ text: String) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > payloadLimit else { return text }
        var end = payloadLimit
        while end > 0, bytes[end] & 0xC0 == 0x80 {
            end -= 1
        }
        let kept = String(decoding: bytes[0..<end], as: UTF8.self)
        return kept + "\n… \(bytes.count - end) more bytes"
    }
}

/// A drop-in `URLSessionWebSocketTask` wrapper that logs every frame.
///
/// Mirrors the task's API, so adopting it is a one-line change at the call
/// site that creates the socket.
public final class OwlseWebSocketTask: @unchecked Sendable {
    /// The underlying task, for anything this wrapper doesn't cover.
    public let task: URLSessionWebSocketTask
    private let store: LoggerStore
    private let url: String

    public init(task: URLSessionWebSocketTask, store: LoggerStore = .shared) {
        self.task = task
        self.store = store
        self.url = task.originalRequest?.url?.absoluteString
            ?? task.currentRequest?.url?.absoluteString
            ?? "websocket"
    }

    public convenience init(url: URL, session: URLSession = .shared, store: LoggerStore = .shared) {
        self.init(task: session.webSocketTask(with: url), store: store)
    }

    public convenience init(request: URLRequest, session: URLSession = .shared, store: LoggerStore = .shared) {
        self.init(task: session.webSocketTask(with: request), store: store)
    }

    public var closeCode: URLSessionWebSocketTask.CloseCode { task.closeCode }
    public var closeReason: Data? { task.closeReason }

    public func resume() {
        log(.sent, .open, 0, "connecting")
        task.resume()
    }

    public func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        let described = WebSocketLogger.describe(message)
        log(.sent, described.kind, described.size, described.text)
        // Strong capture on purpose: nothing else retains this wrapper, and
        // URLSession releases the handler once it fires, so the wrapper lives
        // exactly as long as the in-flight operation.
        task.send(message) { error in
            if let error {
                self.log(.sent, .error, 0, "send failed: \(error.localizedDescription)")
            }
            completionHandler(error)
        }
    }

    public func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let described = WebSocketLogger.describe(message)
        log(.sent, described.kind, described.size, described.text)
        do {
            try await task.send(message)
        } catch {
            log(.sent, .error, 0, "send failed: \(error.localizedDescription)")
            throw error
        }
    }

    public func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        task.receive { result in
            self.logReceived(result)
            completionHandler(result)
        }
    }

    public func receive() async throws -> URLSessionWebSocketTask.Message {
        do {
            let message = try await task.receive()
            logReceived(.success(message))
            return message
        } catch {
            logReceived(.failure(error))
            throw error
        }
    }

    public func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        log(.sent, .ping, 0, "ping")
        task.sendPing { error in
            if let error {
                self.log(.received, .error, 0, "pong failed: \(error.localizedDescription)")
            } else {
                self.log(.received, .pong, 0, "pong")
            }
            pongReceiveHandler(error)
        }
    }

    public func cancel(with closeCode: URLSessionWebSocketTask.CloseCode = .goingAway, reason: Data? = nil) {
        let detail = reason.flatMap { String(data: $0, encoding: .utf8) }
        log(.sent, .close, 0, "closed (code \(closeCode.rawValue))\(detail.map { ": \($0)" } ?? "")")
        task.cancel(with: closeCode, reason: reason)
    }

    private func logReceived(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case .success(let message):
            let described = WebSocketLogger.describe(message)
            log(.received, described.kind, described.size, described.text)
        case .failure(let error):
            log(.received, .error, 0, "receive failed: \(error.localizedDescription)")
        }
    }

    private func log(_ direction: WebSocketLogger.Direction, _ kind: WebSocketLogger.Kind, _ size: Int, _ text: String) {
        WebSocketLogger.record(direction: direction, kind: kind, size: size, text: text, url: url, store: store)
    }
}
