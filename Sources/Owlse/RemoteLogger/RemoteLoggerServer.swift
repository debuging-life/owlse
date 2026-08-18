// The MIT License (MIT)
//
// Copyright (c) 2020-2026 Alexander Grebenyuk (github.com/kean).

import Foundation
import Network
import Combine
import OSLog

/// The server half of the remote logging protocol: advertises itself on the
/// local network over Bonjour, accepts connections from apps that use
/// ``RemoteLogger``, and writes the events they stream into a per-device
/// ``LoggerStore``.
///
/// This is what the Owlse desktop app uses to display logs from the team's
/// devices in real time:
///
/// ```swift
/// try RemoteLoggerServer.shared.start(
///     name: "My Mac",
///     storesDirectory: storesDirectoryURL
/// )
/// ```
///
/// Each connected client (a unique device + app pair) gets its own store
/// created in `storesDirectory`, which persists across reconnects and app
/// launches so past sessions remain browsable.
@available(iOS 16, tvOS 16, macOS 13, watchOS 9, visionOS 1, *)
@MainActor
public final class RemoteLoggerServer: ObservableObject {
    public static let shared = RemoteLoggerServer()

    /// `true` when the Bonjour listener is active.
    @Published public private(set) var isRunning = false

    @Published public private(set) var listenerState: NWListener.State = .setup

    @Published public private(set) var listenerError: NWError?

    /// The name the server is advertised under (may be adjusted by Bonjour
    /// in case of conflicts).
    @Published public private(set) var serverName = ""

    /// Clients that connected during this app run, most recent first.
    /// Clients stay in the list after disconnecting so their logs remain
    /// accessible; ``RemoteLoggerServer/Client/isConnected`` reflects liveness.
    @Published public private(set) var clients: [Client] = []

    /// Emitted when a client uses "Open on Mac" for a log message or a
    /// network task. The event is already stored in the client's store.
    public let detailsRequests = PassthroughSubject<(client: Client, request: DetailsRequest), Never>()

    /// Every event ingested from a device, as it arrives. Device stores are
    /// written with `handleExternalEvent`, which by design does not publish
    /// on the store's own `events` subject — subscribe here instead.
    public let ingestedEvents = PassthroughSubject<(client: Client, event: LoggerStore.Event), Never>()

    /// Response mocks pushed to every connected device: requests whose URL
    /// matches a rule's pattern return the canned response instead of
    /// hitting the network. Persisted across launches.
    @Published public private(set) var mocks: [MockRule] = []

    /// A response mock rule.
    public struct MockRule: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        /// Regex matched against the full request URL (case-insensitive).
        public var pattern: String
        /// HTTP method to match; `nil` matches any method.
        public var method: String?
        public var statusCode: Int
        public var headers: [String: String]
        public var body: String
        /// Artificial latency in seconds before devices deliver the response.
        public var delay: Double

        public init(
            id: UUID = UUID(),
            pattern: String,
            method: String? = nil,
            statusCode: Int = 200,
            headers: [String: String] = [:],
            body: String = "",
            delay: Double = 0
        ) {
            self.id = id
            self.pattern = pattern
            self.method = method
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
            self.delay = delay
        }

        // Rules saved by earlier versions have no delay key
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            pattern = try container.decode(String.self, forKey: .pattern)
            method = try container.decodeIfPresent(String.self, forKey: .method)
            statusCode = try container.decode(Int.self, forKey: .statusCode)
            headers = try container.decode([String: String].self, forKey: .headers)
            body = try container.decode(String.self, forKey: .body)
            delay = try container.decodeIfPresent(Double.self, forKey: .delay) ?? 0
        }
    }

    public enum DetailsRequest {
        case message(LoggerStore.Event.MessageCreated)
        case task(LoggerStore.Event.NetworkTaskCompleted)
    }

    /// The port the server is listening on. Exposed for testing — clients
    /// normally discover the server over Bonjour.
    package var listenerPort: NWEndpoint.Port? { listeners.first?.port }

    /// Also advertised so apps built with the original Pulse SDK can stream
    /// logs to this server — the wire protocol is identical.
    package static let legacyServiceType = "_pulse._tcp"

    private var listeners: [NWListener] = []
    private var storesDirectory: URL?
    private var passcode: String?
    private var connections: [ObjectIdentifier: ConnectionInfo] = [:]
    private var clientsByKey: [String: Client] = [:]
    private var restartItem: DispatchWorkItem?
    /// The name `start` was called with — restarts re-register under this
    /// name, not the possibly Bonjour-renamed `serverName`, so conflict
    /// suffixes don't compound ("Mac (2) (2)…").
    private var requestedServerName = ""
    private let log: OSLog

    private final class ConnectionInfo {
        let connection: RemoteLogger.Connection
        var client: Client?
        var watchdogItem: DispatchWorkItem?

        init(connection: RemoteLogger.Connection) {
            self.connection = connection
        }
    }

    /// A device + app pair that connected to this server.
    @MainActor
    public final class Client: ObservableObject, Identifiable {
        public nonisolated let id: String
        public let deviceInfo: LoggerStore.Info.DeviceInfo
        public let appInfo: LoggerStore.Info.AppInfo
        public let store: LoggerStore

        @Published public internal(set) var isConnected = false
        @Published public private(set) var isPaused = false

        weak var server: RemoteLoggerServer?
        weak var connection: RemoteLogger.Connection?

        public var deviceName: String { deviceInfo.name }
        public var appName: String { appInfo.name ?? appInfo.bundleIdentifier ?? "App" }

        init(id: String, deviceInfo: LoggerStore.Info.DeviceInfo, appInfo: LoggerStore.Info.AppInfo, store: LoggerStore) {
            self.id = id
            self.deviceInfo = deviceInfo
            self.appInfo = appInfo
            self.store = store
        }

        /// Temporarily stops the client from sending events. Events created
        /// while paused are dropped by the client (it only buffers on launch).
        public func pause() {
            isPaused = true
            connection?.send(code: .pause)
        }

        public func resume() {
            isPaused = false
            connection?.send(code: .resume)
        }
    }

    public enum ServerError: Error, LocalizedError {
        case failedToCreateListener(Error)

        public var errorDescription: String? {
            switch self {
            case .failedToCreateListener(let error):
                return "Failed to start the server: \(error.localizedDescription)"
            }
        }
    }

    private static let mocksDefaultsKey = "com.github.kean.owlse.server-mocks"

    private init() {
        let isLogEnabled = UserDefaults.standard.bool(forKey: "com.github.kean.owlse.debug")
        self.log = isLogEnabled ? OSLog(subsystem: "com.github.kean.owlse", category: "RemoteLoggerServer") : .disabled

        if let data = UserDefaults.standard.data(forKey: RemoteLoggerServer.mocksDefaultsKey),
           let saved = try? JSONDecoder().decode([MockRule].self, from: data) {
            self.mocks = saved
        }
    }

    // MARK: Mocks

    /// Replaces the mock rules, persists them, and pushes them to every
    /// connected device immediately.
    public func setMocks(_ rules: [MockRule]) {
        mocks = rules
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: RemoteLoggerServer.mocksDefaultsKey)
        }
        for info in connections.values where info.client?.isConnected == true {
            pushMocks(to: info.connection)
        }
    }

    private func pushMocks(to connection: RemoteLogger.Connection) {
        let wireMocks = mocks.map {
            URLSessionMock(mockID: $0.id, pattern: $0.pattern, method: $0.method)
        }
        connection.sendMessage(path: .updateMocks, entity: wireMocks)
    }

    // MARK: Lifecycle

    /// Starts advertising the server on the local network.
    ///
    /// - parameters:
    ///   - name: The name devices see in their remote logging settings.
    ///   - passcode: When set, connections are protected with TLS using a
    ///   pre-shared key derived from the passcode, and clients are required
    ///   to enter it.
    ///   - storesDirectory: The directory where per-device stores are created.
    public func start(name: String, passcode: String? = nil, storesDirectory: URL) throws {
        stop()

        try FileManager.default.createDirectory(at: storesDirectory, withIntermediateDirectories: true)

        self.serverName = name
        self.requestedServerName = name
        self.passcode = passcode
        self.storesDirectory = storesDirectory

        // The primary listener drives the published state; the legacy one
        // makes the server reachable from apps built with the Pulse SDK.
        let primary = try makeListener(name: name, serviceType: RemoteLogger.serviceType, isPrimary: true)
        var listeners = [primary]
        if let legacy = try? makeListener(name: name, serviceType: RemoteLoggerServer.legacyServiceType, isPrimary: false) {
            listeners.append(legacy)
        }

        self.listeners = listeners
        self.isRunning = true
        for listener in listeners {
            listener.start(queue: .main)
        }

        os_log("Started server %{private}@", log: log, name)
    }

    private func makeListener(name: String, serviceType: String, isPrimary: Bool) throws -> NWListener {
        let parameters: NWParameters
        if let passcode, !passcode.isEmpty {
            // Legacy Pulse SDK clients derive the TLS pre-shared key with a
            // different label — the legacy listener must match it.
            parameters = NWParameters(passcode: passcode, protocolLabel: isPrimary ? .owlse : .legacyPulse)
        } else {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 4
            parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.includePeerToPeer = true
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw ServerError.failedToCreateListener(error)
        }

        var txtRecord = NWTXTRecord()
        txtRecord["protected"] = (passcode?.isEmpty == false) ? "true" : "false"
        listener.service = NWListener.Service(
            name: name,
            type: serviceType,
            domain: nil,
            txtRecord: txtRecord
        )

        if isPrimary {
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    self?.listenerDidUpdateState(state)
                }
            }
            // Bonjour may rename the service when another server with the
            // same name is already advertised — reflect the final name.
            listener.serviceRegistrationUpdateHandler = { [weak self] change in
                if case .add(let endpoint) = change, case .service(let name, _, _, _) = endpoint {
                    DispatchQueue.main.async {
                        self?.serverName = name
                    }
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            DispatchQueue.main.async {
                self?.didReceiveNewConnection(connection)
            }
        }
        return listener
    }

    /// Stops the server and disconnects all clients. Their stores remain
    /// intact and the clients stay listed as disconnected.
    public func stop() {
        restartItem?.cancel()
        restartItem = nil

        guard !listeners.isEmpty || !connections.isEmpty else {
            isRunning = false
            return
        }

        os_log("Stopping server", log: log)

        for listener in listeners {
            listener.stateUpdateHandler = nil
            listener.serviceRegistrationUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
        }
        listeners = []

        for info in connections.values {
            info.watchdogItem?.cancel()
            info.connection.cancel()
            info.client?.isConnected = false
        }
        connections.removeAll()

        isRunning = false
        listenerState = .cancelled
        listenerError = nil
    }

    /// Removes a disconnected client from the list and closes its store.
    /// The store files on disk are left intact, so the device's history
    /// returns if it reconnects. Connected clients cannot be removed.
    public func removeClient(_ client: Client) {
        guard !client.isConnected else { return }
        clients.removeAll { $0 === client }
        clientsByKey.removeValue(forKey: client.id)
        try? client.store.close()
    }

    /// Removes all clients and their in-memory stores. The store files on
    /// disk are left intact. Used by tests and when clearing history.
    package func removeAllClients() {
        for info in connections.values {
            info.watchdogItem?.cancel()
            info.connection.cancel()
        }
        connections.removeAll()
        for client in clients {
            try? client.store.close()
        }
        clients.removeAll()
        clientsByKey.removeAll()
    }

    private func listenerDidUpdateState(_ state: NWListener.State) {
        // A handler enqueued before stop() can fire after it — ignore it
        guard isRunning else { return }

        os_log("Listener did update state: %{public}@", log: log, "\(state)")

        listenerState = state
        switch state {
        case .waiting(let error), .failed(let error):
            listenerError = error
            scheduleRestart()
        case .ready:
            listenerError = nil
            // The listener healed on its own — no restart needed
            restartItem?.cancel()
            restartItem = nil
        default:
            break
        }
    }

    private func scheduleRestart() {
        guard isRunning, restartItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartItem = nil
            // Only restart if the listener is still unhealthy — a transient
            // .waiting often recovers by itself, and bouncing the server
            // disconnects every client.
            guard self.isRunning, self.listenerState != .ready, let directory = self.storesDirectory else { return }
            os_log("Restarting listener after failure", log: self.log)
            try? self.start(name: self.requestedServerName, passcode: self.passcode, storesDirectory: directory)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(5), execute: item)
        restartItem = item
    }

    // MARK: Connections

    private func didReceiveNewConnection(_ connection: NWConnection) {
        // The handler block may already be in flight on the main queue when
        // stop() runs — don't accept connections for a stopped server.
        guard isRunning else {
            connection.cancel()
            return
        }

        os_log("Did receive connection from %{private}@", log: log, "\(connection.endpoint)")

        let wrapped = RemoteLogger.Connection(connection, delegate: self)
        connections[ObjectIdentifier(wrapped)] = ConnectionInfo(connection: wrapped)
        wrapped.start()
        scheduleWatchdog(for: wrapped)
    }

    private func drop(_ connection: RemoteLogger.Connection) {
        guard let info = connections.removeValue(forKey: ObjectIdentifier(connection)) else { return }
        info.watchdogItem?.cancel()
        info.connection.cancel()
        if let client = info.client, client.connection === info.connection {
            client.connection = nil
            client.isConnected = false
        }
    }

    /// Disconnects the connection if the client stops sending pings (the
    /// client pings every 2 seconds while connected).
    private func scheduleWatchdog(for connection: RemoteLogger.Connection) {
        guard let info = connections[ObjectIdentifier(connection)] else { return }
        info.watchdogItem?.cancel()
        let item = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else { return }
            os_log("Connection timed out", log: self.log)
            self.drop(connection)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(8), execute: item)
        info.watchdogItem = item
    }

    // MARK: Handshake

    private func didReceiveHello(_ hello: RemoteLogger.PacketClientHello, from connection: RemoteLogger.Connection) {
        guard let info = connections[ObjectIdentifier(connection)] else { return }

        os_log("Did receive hello from %{private}@ (%{private}@)", log: log, hello.deviceInfo.name, hello.appInfo.name ?? "–")

        let key = "\(hello.deviceId.uuidString)|\(hello.appInfo.bundleIdentifier ?? "app")"

        let client: Client
        if let existing = clientsByKey[key] {
            client = existing
        } else {
            do {
                client = try makeClient(key: key, hello: hello)
            } catch {
                os_log("Failed to create a store for the client: %{public}@", log: log, type: .error, "\(error)")
                drop(connection)
                return
            }
            clientsByKey[key] = client
            clients.insert(client, at: 0)
        }

        // Replace a lingering previous connection for the same client
        if let previous = client.connection, previous !== connection {
            drop(previous)
        }

        info.client = client
        client.server = self
        client.connection = connection
        client.isConnected = true

        client.store.startSession(hello.session ?? .init(), info: hello.appInfo)

        connection.send(code: .serverHello, entity: RemoteLogger.ServerHelloResponse(version: LoggerStore.Version.currentProtocolVersion.description))
        // Always send the authoritative pause state: a reconnecting client
        // keeps its previous in-process state, so a client that was streaming
        // before a Wi-Fi blip would otherwise keep streaming while the UI
        // shows it as paused (and vice versa).
        connection.send(code: client.isPaused ? .pause : .resume)

        // Always push, even when empty — an empty array authoritatively
        // clears mocks a device cached from a previous session.
        pushMocks(to: connection)
    }

    private func makeClient(key: String, hello: RemoteLogger.PacketClientHello) throws -> Client {
        guard let storesDirectory else {
            throw ServerError.failedToCreateListener(URLError(.unknown))
        }
        var configuration = LoggerStore.Configuration()
        configuration.isAutoStartingSession = false

        let store = try LoggerStore(
            storeURL: storesDirectory.appendingPathComponent(storeFilename(key: key, hello: hello), isDirectory: true),
            options: [.create, .sweep],
            configuration: configuration
        )
        return Client(id: key, deviceInfo: hello.deviceInfo, appInfo: hello.appInfo, store: store)
    }

    private func storeFilename(key: String, hello: RemoteLogger.PacketClientHello) -> String {
        let base = "\(hello.deviceInfo.name) - \(hello.appInfo.name ?? hello.appInfo.bundleIdentifier ?? "App")"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        let sanitized = String(base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        // A stable per-client suffix so renamed devices don't collide
        let suffix = String(format: "%08x", UInt32(truncatingIfNeeded: stableHash(key)))
        return "\(sanitized)-\(suffix).owlse"
    }

    /// A stable (cross-launch) variant of `hashValue`, which is seeded per-process.
    private func stableHash(_ string: String) -> UInt64 {
        var result: UInt64 = 5381
        for byte in string.utf8 {
            result = 127 &* (result & 0x00ffffffffffffff) &+ UInt64(byte)
        }
        return result
    }

    // MARK: Messages

    private func didReceive(packet: RemoteLogger.Connection.Packet, from connection: RemoteLogger.Connection) {
        let code = RemoteLogger.PacketCode(rawValue: packet.code)
        switch code {
        case .clientHello:
            do {
                let hello = try JSONDecoder().decode(RemoteLogger.PacketClientHello.self, from: packet.body)
                didReceiveHello(hello, from: connection)
            } catch {
                os_log("Failed to decode client hello: %{public}@", log: log, type: .error, "\(error)")
                drop(connection)
            }
        case .ping:
            scheduleWatchdog(for: connection)
            connection.send(code: .ping)
        case .storeEventMessageStored, .storeEventNetworkTaskCreated, .storeEventNetworkTaskProgressUpdated, .storeEventNetworkTaskCompleted:
            guard let client = connections[ObjectIdentifier(connection)]?.client else {
                return os_log("Received a store event before the handshake", log: log, type: .error)
            }
            // Defense in depth: a paused client shouldn't be sending events;
            // drop them if it does (e.g. a pause packet still in flight).
            guard !client.isPaused else { return }
            do {
                let event = try ingest(code: code!, body: packet.body, into: client.store)
                ingestedEvents.send((client, event))
            } catch {
                os_log("Failed to decode a store event: %{public}@", log: log, type: .error, "\(error)")
            }
        case .message:
            guard let message = try? RemoteLogger.Message.decode(packet.body) else { return }
            didReceive(message: message, from: connection)
        case .serverHello, .pause, .resume, .none:
            break // Client-bound or unknown codes
        }
    }

    @discardableResult
    private func ingest(code: RemoteLogger.PacketCode, body: Data, into store: LoggerStore) throws -> LoggerStore.Event {
        let event: LoggerStore.Event
        switch code {
        case .storeEventMessageStored:
            event = .messageStored(try JSONDecoder().decode(LoggerStore.Event.MessageCreated.self, from: body))
        case .storeEventNetworkTaskCreated:
            event = .networkTaskCreated(try JSONDecoder().decode(LoggerStore.Event.NetworkTaskCreated.self, from: body))
        case .storeEventNetworkTaskProgressUpdated:
            event = .networkTaskProgressUpdated(try JSONDecoder().decode(LoggerStore.Event.NetworkTaskProgressUpdated.self, from: body))
        case .storeEventNetworkTaskCompleted:
            event = .networkTaskCompleted(try RemoteLogger.PacketNetworkMessage.decode(body))
        default:
            throw RemoteLogger.PacketParsingError.notEnoughData
        }
        store.handleExternalEvent(event)
        return event
    }

    private func didReceive(message: RemoteLogger.Message, from connection: RemoteLogger.Connection) {
        guard let client = connections[ObjectIdentifier(connection)]?.client else { return }
        switch message.path {
        case .openMessageDetails:
            guard let event = try? JSONDecoder().decode(LoggerStore.Event.MessageCreated.self, from: message.data) else { return }
            // Unlike tasks (deduped by taskId), messages have no identity —
            // storing here would duplicate an already-streamed message.
            detailsRequests.send((client, .message(event)))
        case .openTaskDetails:
            guard let event = try? JSONDecoder().decode(LoggerStore.Event.NetworkTaskCompleted.self, from: message.data) else { return }
            client.store.handleExternalEvent(.networkTaskCompleted(event))
            detailsRequests.send((client, .task(event)))
        case .getMockedResponse(let mockID):
            guard let rule = mocks.first(where: { $0.id == mockID }) else {
                // Never leave the device hanging: it waits 20s for a reply
                // before failing the request outright.
                connection.sendResponse(for: message, entity: URLSessionMockedResponse(
                    errorCode: nil, statusCode: nil, headers: nil
                ))
                return
            }
            var headers = rule.headers
            if headers["Content-Type"] == nil, !rule.body.isEmpty {
                headers["Content-Type"] = "application/json"
            }
            connection.sendResponse(for: message, entity: URLSessionMockedResponse(
                errorCode: nil,
                statusCode: rule.statusCode,
                headers: headers,
                body: rule.body,
                delay: rule.delay > 0 ? rule.delay : nil
            ))
        case .updateMocks:
            break // Client-bound only
        case .crashReportStored:
            guard let report = try? JSONDecoder().decode(LoggerStore.Event.CrashReport.self, from: message.data) else { return }
            ingestedEvents.send((client, .crashReportStored(report)))
        }
    }
}

@available(iOS 16, tvOS 16, macOS 13, watchOS 9, visionOS 1, *)
extension RemoteLoggerServer: RemoteLoggerConnectionDelegate {
    package func connection(_ connection: RemoteLogger.Connection, didChangeState newState: NWConnection.State) {
        os_log("Connection did change state: %{public}@", log: log, "\(newState)")
        switch newState {
        case .failed, .cancelled:
            drop(connection)
        default:
            break
        }
    }

    package func connection(_ connection: RemoteLogger.Connection, didReceiveEvent event: RemoteLogger.Connection.Event) {
        switch event {
        case .packet(let packet):
            didReceive(packet: packet, from: connection)
        case .error(let error):
            os_log("Connection did fail: %{public}@", log: log, type: .error, "\(error)")
            drop(connection)
        case .completed:
            drop(connection)
        }
    }
}
