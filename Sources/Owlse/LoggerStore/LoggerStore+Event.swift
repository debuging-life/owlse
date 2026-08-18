// The MIT License (MIT)
//
// Copyright (c) 2020-2026 Alexander Grebenyuk (github.com/kean).

import Foundation

extension LoggerStore {
    /// The events used for syncing data between stores.
    @frozen public enum Event: Sendable {
        case messageStored(MessageCreated)
        case networkTaskCreated(NetworkTaskCreated)
        case networkTaskProgressUpdated(NetworkTaskProgressUpdated)
        case networkTaskCompleted(NetworkTaskCompleted)

        public struct MessageCreated: Codable, Sendable {
            public var createdAt: Date
            public var label: String
            public var level: LoggerStore.Level
            public var message: String
            public var metadata: [String: String]?
            public var file: String
            public var function: String
            public var line: UInt

            @available(*, deprecated, message: "Deprecated (added for backward compatibility)")
            public var session: UUID? = Session.current.id

            public init(createdAt: Date, label: String, level: LoggerStore.Level, message: String, metadata: [String: String]?, file: String, function: String, line: UInt) {
                self.createdAt = createdAt
                self.label = label
                self.level = level
                self.message = message
                self.metadata = metadata
                self.file = file
                self.function = function
                self.line = line
            }

            init(_ entity: LoggerMessageEntity) {
                self.createdAt = entity.createdAt
                self.label = entity.label
                self.level = LoggerStore.Level(rawValue: entity.level) ?? .debug
                self.message = entity.text
                self.metadata = entity.metadata
                self.file = entity.file
                self.function = entity.function
                self.line = UInt(entity.line)
            }
        }

        public struct NetworkTaskCreated: Codable, Sendable, NetworkTaskEvent {
            public var taskId: UUID
            public var taskType: NetworkLogger.TaskType
            public var createdAt: Date
            public var originalRequest: NetworkLogger.Request
            public var currentRequest: NetworkLogger.Request?
            public var label: String?
            public var taskDescription: String?

            @available(*, deprecated, message: "Deprecated (added for backward compatibility)")
            public var session: UUID? = Session.current.id

            public init(taskId: UUID, taskType: NetworkLogger.TaskType, createdAt: Date, originalRequest: NetworkLogger.Request, currentRequest: NetworkLogger.Request?, label: String?, taskDescription: String?) {
                self.taskId = taskId
                self.taskType = taskType
                self.createdAt = createdAt
                self.originalRequest = originalRequest
                self.currentRequest = currentRequest
                self.label = label
                self.taskDescription = taskDescription
            }
        }

        public struct NetworkTaskProgressUpdated: Codable, Sendable {
            public var taskId: UUID
            public var url: URL?
            public var completedUnitCount: Int64
            public var totalUnitCount: Int64

            public init(taskId: UUID, url: URL?, completedUnitCount: Int64, totalUnitCount: Int64) {
                self.taskId = taskId
                self.url = url
                self.completedUnitCount = completedUnitCount
                self.totalUnitCount = totalUnitCount
            }
        }

        public struct NetworkTaskCompleted: Codable, Sendable, NetworkTaskEvent {
            public var taskId: UUID
            public var taskType: NetworkLogger.TaskType
            public var createdAt: Date
            public var originalRequest: NetworkLogger.Request
            public var currentRequest: NetworkLogger.Request?
            public var response: NetworkLogger.Response?
            public var error: NetworkLogger.ResponseError?
            public var requestBody: Data?
            public var responseBody: Data?
            public var metrics: NetworkLogger.Metrics?
            public var label: String?
            public var taskDescription: String?

            @available(*, deprecated, message: "Deprecated (added for backward compatibility)")
            public var session: UUID? = Session.current.id

            public init(taskId: UUID, taskType: NetworkLogger.TaskType, createdAt: Date, originalRequest: NetworkLogger.Request, currentRequest: NetworkLogger.Request?, response: NetworkLogger.Response?, error: NetworkLogger.ResponseError?, requestBody: Data?, responseBody: Data?, metrics: NetworkLogger.Metrics?, label: String?, taskDescription: String?) {
                self.taskId = taskId
                self.taskType = taskType
                self.createdAt = createdAt
                self.originalRequest = originalRequest
                self.currentRequest = currentRequest
                self.response = response
                self.error = error
                self.requestBody = requestBody
                self.responseBody = responseBody
                self.metrics = metrics
                self.label = label
                self.taskDescription = taskDescription
            }

            init(_ entity: NetworkTaskEntity) {
                self.taskId = entity.taskId
                self.taskType = NetworkLogger.TaskType(rawValue: entity.taskType) ?? .dataTask
                self.createdAt = entity.createdAt
                self.originalRequest = (entity.currentRequest.map(NetworkLogger.Request.init)) ?? .init(.init())
                self.currentRequest = entity.currentRequest.map(NetworkLogger.Request.init)
                self.response = entity.response.map(NetworkLogger.Response.init)
                self.error = entity.error.map(NetworkLogger.ResponseError.init)
                self.requestBody = entity.requestBody?.data
                self.responseBody = entity.responseBody?.data
                if entity.hasMetrics, let interval = entity.taskInterval {
                    let transactions = entity.orderedTransactions.map {
                        NetworkLogger.TransactionMetrics($0)
                    }
                    self.metrics = NetworkLogger.Metrics(taskInterval: interval, redirectCount: Int(entity.redirectCount), transactions: transactions)
                }
                self.label = entity.message?.label
                self.taskDescription = entity.taskDescription
            }
        }

        case crashReportStored(CrashReport)

        var url: URL? {
            switch self {
            case .messageStored, .crashReportStored:
                return nil
            case .networkTaskCreated(let event):
                return event.originalRequest.url
            case .networkTaskProgressUpdated(let event):
                return event.url
            case .networkTaskCompleted(let event):
                return event.originalRequest.url
            }
        }

        // MARK: - Crash Report Types

        public struct CrashReport: Codable, Sendable, Identifiable {
            public var id: UUID
            public var crashedAt: Date
            public var exceptionType: String
            public var exceptionReason: String
            public var signal: String?
            public var threads: [CrashThread]
            public var crashedThreadIndex: Int
            public var appVersion: String?
            public var buildNumber: String?
            public var osVersion: String?
            public var deviceModel: String?
            public var metadata: [String: String]?

            public init(id: UUID, crashedAt: Date, exceptionType: String, exceptionReason: String,
                        signal: String?, threads: [CrashThread], crashedThreadIndex: Int,
                        appVersion: String? = nil, buildNumber: String? = nil,
                        osVersion: String? = nil, deviceModel: String? = nil,
                        metadata: [String: String]? = nil) {
                self.id = id
                self.crashedAt = crashedAt
                self.exceptionType = exceptionType
                self.exceptionReason = exceptionReason
                self.signal = signal
                self.threads = threads
                self.crashedThreadIndex = crashedThreadIndex
                self.appVersion = appVersion
                self.buildNumber = buildNumber
                self.osVersion = osVersion
                self.deviceModel = deviceModel
                self.metadata = metadata
            }
        }

        public struct CrashThread: Codable, Sendable {
            public var index: Int
            public var name: String?
            public var frames: [CrashFrame]
            public var isCrashed: Bool

            public init(index: Int, name: String?, frames: [CrashFrame], isCrashed: Bool) {
                self.index = index
                self.name = name
                self.frames = frames
                self.isCrashed = isCrashed
            }
        }

        public struct CrashFrame: Codable, Sendable {
            public var index: Int
            public var binaryName: String?
            public var address: UInt64?
            public var symbol: String?

            public init(index: Int, binaryName: String? = nil, address: UInt64? = nil, symbol: String? = nil) {
                self.index = index
                self.binaryName = binaryName
                self.address = address
                self.symbol = symbol
            }
        }
    }
}

protocol NetworkTaskEvent {
    var taskId: UUID { get }
    var taskType: NetworkLogger.TaskType { get }
    var createdAt: Date { get }
    var label: String? { get }
    var originalRequest: NetworkLogger.Request { get }
    var taskDescription: String? { get }
}
