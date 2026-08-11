// The MIT License (MIT)
//
// Copyright (c) 2020-2026 Alexander Grebenyuk (github.com/kean).

import Foundation

final class NetworkDebugger: @unchecked Sendable {
    /// Kept as an ordered array, not a dictionary: when two rules match the
    /// same URL the first one the server sent must win, deterministically.
    private var mocks: [URLSessionMock] = []

    // Number of handled requests per mock.
    private var numberOfHandledRequests: [UUID: Int] = [:]
    private var mockedTaskIDs: Set<Int> = []

    private let lock = NSLock()

    static let shared = NetworkDebugger()

    func getMock(for request: URLRequest) -> URLSessionMock? {
        lock.lock()
        defer { lock.unlock() }
        return _getMock(for: request)
    }

    func shouldMock(_ request: URLRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let mock = _getMock(for: request) else {
            return false
        }
        defer { numberOfHandledRequests[mock.mockID, default: 0] += 1 }
        let count = numberOfHandledRequests[mock.mockID, default: 0]
        if count < (mock.skip ?? 0) {
            return false // Skip the first N requests
        }
        if let maxCount = mock.count, count - (mock.skip ?? 0) >= maxCount {
            return false // Mock for N number of times
        }
        return true
    }

    private func _getMock(for request: URLRequest) -> URLSessionMock? {
        mocks.first { $0.isMatch(request) }
    }

    func update(_ mocks: [URLSessionMock]) {
        lock.lock()
        defer { lock.unlock() }

        self.mocks = mocks
    }
}
