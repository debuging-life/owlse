// The MIT License (MIT)
//
// Copyright (c) 2020-2026 Alexander Grebenyuk (github.com/kean).

import XCTest
import Network
@testable import Owlse

/// Exercises ``RemoteLoggerServer`` with a raw protocol client: connects
/// directly to the listener port (bypassing Bonjour discovery), performs the
/// handshake, streams events, and verifies they end up in the device store.
@available(iOS 16, tvOS 16, macOS 13, watchOS 9, *)
@MainActor
final class RemoteLoggerServerTests: XCTestCase {
    private var directory: URL!
    private var client: TestClient?

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("owlse-server-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        client?.cancel()
        RemoteLoggerServer.shared.stop()
        RemoteLoggerServer.shared.removeAllClients()
        try? FileManager.default.removeItem(at: directory)
    }

    func testHandshakeAndMessageIngestion() async throws {
        let server = RemoteLoggerServer.shared
        try server.start(name: "Owlse Tests", storesDirectory: directory)

        let port = try await waitForListenerPort(server)
        let client = TestClient(port: port)
        self.client = client
        try await connect(client)

        // Handshake: hello → serverHello + resume
        let deviceId = UUID()
        client.sendHello(deviceId: deviceId, deviceName: "Test Device", session: .init())

        try await wait(timeout: 5, description: "handshake completed") {
            client.receivedCodes.contains(RemoteLogger.PacketCode.serverHello.rawValue)
                && client.receivedCodes.contains(RemoteLogger.PacketCode.resume.rawValue)
        }

        XCTAssertEqual(server.clients.count, 1)
        let connected = try XCTUnwrap(server.clients.first)
        XCTAssertTrue(connected.isConnected)
        XCTAssertEqual(connected.deviceName, "Test Device")

        // Stream a log message and verify it lands in the device store
        let event = LoggerStore.Event.MessageCreated(
            createdAt: Date(),
            label: "test",
            level: .info,
            message: "Hello from the test device",
            metadata: nil,
            file: "Test.swift",
            function: "test()",
            line: 1
        )
        client.send(code: .storeEventMessageStored, entity: event)

        try await wait(timeout: 5, description: "message ingested") {
            let messages = (try? connected.store.allMessages()) ?? []
            return messages.contains { $0.text == "Hello from the test device" }
        }

        // Ping keeps the connection alive and is echoed back
        client.send(code: .ping)
        try await wait(timeout: 5, description: "ping echoed") {
            client.receivedCodes.contains(RemoteLogger.PacketCode.ping.rawValue)
        }
    }

    func testNetworkTaskCompletedIngestion() async throws {
        let server = RemoteLoggerServer.shared
        try server.start(name: "Owlse Tests", storesDirectory: directory)

        let port = try await waitForListenerPort(server)
        let client = TestClient(port: port)
        self.client = client
        try await connect(client)

        client.sendHello(deviceId: UUID(), deviceName: "Test Device", session: .init())
        try await wait(timeout: 5, description: "handshake completed") {
            client.receivedCodes.contains(RemoteLogger.PacketCode.serverHello.rawValue)
        }
        let connected = try XCTUnwrap(server.clients.first)

        // Encode a completed network task the same way the client SDK does
        let url = URL(string: "https://example.com/api/items")!
        let request = URLRequest(url: url)
        let taskEvent = LoggerStore.Event.NetworkTaskCompleted(
            taskId: UUID(),
            taskType: .dataTask,
            createdAt: Date(),
            originalRequest: NetworkLogger.Request(request),
            currentRequest: nil,
            response: nil,
            error: nil,
            requestBody: nil,
            responseBody: "{\"items\":[]}".data(using: .utf8),
            metrics: nil,
            label: nil,
            taskDescription: nil
        )
        let payload = try RemoteLogger.PacketNetworkMessage.encode(taskEvent)
        client.send(code: .storeEventNetworkTaskCompleted, data: payload)

        try await wait(timeout: 5, description: "task ingested") {
            let tasks = (try? connected.store.allTasks()) ?? []
            return tasks.contains { $0.url == url.absoluteString }
        }
    }

    func testReconnectReusesStore() async throws {
        let server = RemoteLoggerServer.shared
        try server.start(name: "Owlse Tests", storesDirectory: directory)
        let port = try await waitForListenerPort(server)

        let deviceId = UUID()

        let first = TestClient(port: port)
        try await connect(first)
        first.sendHello(deviceId: deviceId, deviceName: "Test Device", session: .init())
        try await wait(timeout: 5, description: "first handshake") {
            first.receivedCodes.contains(RemoteLogger.PacketCode.serverHello.rawValue)
        }
        XCTAssertEqual(server.clients.count, 1)
        let originalClient = try XCTUnwrap(server.clients.first)
        let originalStoreURL = originalClient.store.storeURL
        first.cancel()

        let second = TestClient(port: port)
        self.client = second
        try await connect(second)
        second.sendHello(deviceId: deviceId, deviceName: "Test Device", session: .init())
        try await wait(timeout: 5, description: "second handshake") {
            second.receivedCodes.contains(RemoteLogger.PacketCode.serverHello.rawValue)
        }

        // Same device + app → the same client entry and the same store
        // instance, not a duplicate
        XCTAssertEqual(server.clients.count, 1)
        let reconnected = try XCTUnwrap(server.clients.first)
        XCTAssertTrue(reconnected === originalClient)
        XCTAssertTrue(reconnected.store === originalClient.store)
        XCTAssertEqual(reconnected.store.storeURL, originalStoreURL)
        XCTAssertTrue(reconnected.isConnected)
    }

    func testPasscodeProtectedConnection() async throws {
        let server = RemoteLoggerServer.shared
        try server.start(name: "Owlse Tests", passcode: "owl-secret", storesDirectory: directory)

        let port = try await waitForListenerPort(server)
        let client = TestClient(port: port, parameters: NWParameters(passcode: "owl-secret"))
        self.client = client
        try await connect(client)

        client.sendHello(deviceId: UUID(), deviceName: "Secure Device", session: .init())
        try await wait(timeout: 5, description: "TLS handshake completed") {
            client.receivedCodes.contains(RemoteLogger.PacketCode.serverHello.rawValue)
        }
        XCTAssertEqual(server.clients.first?.deviceName, "Secure Device")
    }

    func testWatchdogDisconnectsSilentConnection() async throws {
        let server = RemoteLoggerServer.shared
        try server.start(name: "Owlse Tests", storesDirectory: directory)

        let port = try await waitForListenerPort(server)
        let client = TestClient(port: port)
        self.client = client
        try await connect(client)
        client.sendHello(deviceId: UUID(), deviceName: "Silent Device", session: .init())
        try await wait(timeout: 5, description: "handshake completed") {
            client.receivedCodes.contains(RemoteLogger.PacketCode.serverHello.rawValue)
        }

        // Stop pinging — the server should drop the connection after ~8s
        client.stopPinging()
        try await wait(timeout: 15, description: "watchdog disconnected the client") {
            server.clients.first?.isConnected == false
        }
    }

    func testMalformedPacketsDoNotBreakTheServer() async throws {
        let server = RemoteLoggerServer.shared
        try server.start(name: "Owlse Tests", storesDirectory: directory)

        let port = try await waitForListenerPort(server)
        let client = TestClient(port: port)
        self.client = client
        try await connect(client)

        // Store event before the handshake — must be ignored
        client.send(code: .storeEventMessageStored, data: Data([0x01, 0x02]))
        // Garbage hello — must not create a client
        client.send(code: .clientHello, data: Data("not json".utf8))
        // Unknown packet code
        client.send(code: RemoteLogger.PacketCode.message, data: Data([0xFF]))

        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(server.clients.isEmpty)

        // The server keeps serving valid clients afterwards
        let healthy = TestClient(port: port)
        defer { healthy.cancel() }
        try await connect(healthy)
        healthy.sendHello(deviceId: UUID(), deviceName: "Healthy Device", session: .init())
        try await wait(timeout: 5, description: "healthy handshake after malformed input") {
            healthy.receivedCodes.contains(RemoteLogger.PacketCode.serverHello.rawValue)
        }
    }

    func testMocksPushedOnHelloAndServedOnRequest() async throws {
        let server = RemoteLoggerServer.shared
        let rule = RemoteLoggerServer.MockRule(
            pattern: "api/v1/products",
            method: "GET",
            statusCode: 418,
            body: #"{"mocked":true}"#
        )
        server.setMocks([rule])
        defer { server.setMocks([]) }
        try server.start(name: "Owlse Tests", storesDirectory: directory)

        let port = try await waitForListenerPort(server)
        let client = TestClient(port: port)
        self.client = client
        try await connect(client)
        client.sendHello(deviceId: UUID(), deviceName: "Mock Device", session: .init())

        // The server pushes the mock rules right after the handshake
        try await wait(timeout: 5, description: "mocks pushed") {
            client.receivedMocks.contains { $0.mockID == rule.id }
        }

        // Asking for the mocked response returns the canned payload
        var received: URLSessionMockedResponse?
        client.connection.sendMessage(path: .getMockedResponse(mockID: rule.id)) { data, _ in
            received = data.flatMap { try? JSONDecoder().decode(URLSessionMockedResponse.self, from: $0) }
        }
        try await wait(timeout: 5, description: "mocked response served") {
            received != nil
        }
        XCTAssertEqual(received?.statusCode, 418)
        XCTAssertEqual(received?.body, #"{"mocked":true}"#)
    }

    /// The desktop app's file-open path: a store exported as a flat archive
    /// (the default `.owlse` share format) must open for viewing.
    func testOpenForViewingExportedArchive() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Create a store with one message and export it as an archive
        let packageURL = directory.appendingPathComponent("source.owlse", isDirectory: true)
        let store = try LoggerStore(storeURL: packageURL, options: [.create])
        store.storeMessage(label: "test", level: .info, message: "Archived message")
        // Writes are batched (saveInterval is 300 ms) — let them land
        try await Task.sleep(nanoseconds: 700_000_000)
        let archiveURL = directory.appendingPathComponent("export.owlse")
        try await store.export(to: archiveURL)
        try store.close()

        // Open the flat archive the way the app does
        let viewer = try LoggerStore.openForViewing(at: archiveURL)
        defer {
            let storeURL = viewer.storeURL
            try? viewer.close()
            try? FileManager.default.removeItem(at: storeURL)
        }
        XCTAssertNotEqual(viewer.storeURL, archiveURL, "archives are unpacked to a temporary package")
        let messages = try viewer.allMessages()
        XCTAssertTrue(messages.contains { $0.text == "Archived message" })

        // And a package directory opens in place
        let direct = try LoggerStore.openForViewing(at: packageURL)
        defer { try? direct.close() }
        XCTAssertEqual(direct.storeURL, packageURL)
    }

    // MARK: Helpers

    private func waitForListenerPort(_ server: RemoteLoggerServer) async throws -> NWEndpoint.Port {
        try await wait(timeout: 5, description: "listener ready") {
            server.listenerState == .ready && server.listenerPort != nil && server.listenerPort?.rawValue != 0
        }
        return try XCTUnwrap(server.listenerPort)
    }

    private func connect(_ client: TestClient) async throws {
        client.start()
        try await wait(timeout: 5, description: "client connected") {
            client.isReady
        }
    }

    private struct TimeoutError: Error {
        let description: String
    }

    private func wait(timeout: TimeInterval, description: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for: \(description)")
        throw TimeoutError(description: description)
    }
}

/// A minimal protocol client speaking directly to the server over TCP.
@available(iOS 16, tvOS 16, macOS 13, watchOS 9, *)
@MainActor
private final class TestClient: RemoteLoggerConnectionDelegate {
    let connection: RemoteLogger.Connection
    private(set) var receivedCodes: [UInt8] = []
    private(set) var receivedMocks: [URLSessionMock] = []
    private(set) var isCompleted = false
    private(set) var isReady = false

    private var pingTimer: Timer?

    init(port: NWEndpoint.Port, parameters: NWParameters = .tcp) {
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        self.connection = RemoteLogger.Connection(endpoint: endpoint, using: parameters)
        self.connection.delegate = self
    }

    func start() {
        connection.start()
        // Keep the server's 8s ping watchdog fed for the whole test,
        // mirroring the real client's 2s ping cadence.
        pingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.send(code: .ping)
            }
        }
    }

    func cancel() {
        stopPinging()
        connection.cancel()
    }

    func stopPinging() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    func sendHello(deviceId: UUID, deviceName: String, session: LoggerStore.Session) {
        let hello = RemoteLogger.PacketClientHello(
            version: LoggerStore.Version.currentProtocolVersion.description,
            deviceId: deviceId,
            deviceInfo: .init(
                name: deviceName,
                model: "TestModel",
                localizedModel: "TestModel",
                systemName: "TestOS",
                systemVersion: "1.0"
            ),
            appInfo: .init(
                bundleIdentifier: "com.owlse.tests",
                name: "OwlseTests",
                version: "1.0",
                build: "1",
                icon: nil
            ),
            session: session
        )
        send(code: .clientHello, entity: hello)
    }

    func send<T: Encodable>(code: RemoteLogger.PacketCode, entity: T) {
        connection.send(code: code, entity: entity)
    }

    func send(code: RemoteLogger.PacketCode, data: Data) {
        connection.send(code: code, data: data)
    }

    func send(code: RemoteLogger.PacketCode) {
        connection.send(code: code)
    }

    // MARK: RemoteLoggerConnectionDelegate

    func connection(_ connection: RemoteLogger.Connection, didChangeState newState: NWConnection.State) {
        if case .ready = newState {
            isReady = true
        }
    }

    func connection(_ connection: RemoteLogger.Connection, didReceiveEvent event: RemoteLogger.Connection.Event) {
        switch event {
        case .packet(let packet):
            receivedCodes.append(packet.code)
            if packet.code == RemoteLogger.PacketCode.message.rawValue,
               let message = try? RemoteLogger.Message.decode(packet.body),
               case .updateMocks = message.path,
               let mocks = try? JSONDecoder().decode([URLSessionMock].self, from: message.data) {
                receivedMocks.append(contentsOf: mocks)
            }
        case .completed:
            isCompleted = true
        case .error:
            break
        }
    }
}
