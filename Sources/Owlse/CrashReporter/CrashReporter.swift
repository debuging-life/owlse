// The MIT License (MIT)
//
// Owlse — free desktop log viewer for the Owlse SDK.

import Foundation

/// Installs process-level crash handlers that write a ``LoggerStore/Event/CrashReport``
/// to disk when the app terminates abnormally, and optionally uploads them to a
/// remote endpoint for production crash tracking.
///
/// **Development flow** — crashes stream to the Owlse desktop app over Bonjour:
/// ```swift
/// CrashReporter.install()
/// RemoteLogger.shared.initialize(store: .shared)
/// RemoteLogger.shared.isAutomaticConnectionEnabled = true
/// RemoteLogger.shared.sendPendingCrashReports()
/// ```
///
/// **Production flow** — crashes are uploaded to your backend on next launch:
/// ```swift
/// CrashReporter.configure(
///     uploadURL: URL(string: "https://owlse-crash-reporter.loudowls05.workers.dev/report")!,
///     apiKey: "YOUR_OWLSE_API_KEY"
/// )
/// CrashReporter.install()
/// // on next launch:
/// CrashReporter.uploadPendingReports()
/// ```
///
/// Both flows are independent and can run together. A report written during a crash
/// is sent via Bonjour (if a desktop is connected) and uploaded via HTTP on the
/// next launch (if an endpoint is configured).
public enum CrashReporter {

    // MARK: - Configuration

    /// Configure the remote HTTP upload endpoint. Call before ``install()``.
    ///
    /// - Parameters:
    ///   - uploadURL: The URL of your crash ingestion endpoint (e.g. a Cloudflare Worker).
    ///   - apiKey: An API key included in every upload request for authentication.
    public static func configure(uploadURL: URL, apiKey: String) {
        Self.uploadURL = uploadURL
        Self.apiKey = apiKey
    }

    private static var uploadURL: URL?
    private static var apiKey: String?
    private static let uploadedIDsKey = "com.owlse.crashes.uploaded-ids"

    // MARK: - Public API

    /// Installs the uncaught-exception handler and POSIX signal handlers.
    /// Safe to call from any thread; no-op after the first call.
    public static func install() {
        installOnce
    }

    /// Reads pending crash reports and POSTs each one to the endpoint set in
    /// ``configure(uploadURL:apiKey:)``. Runs on a background thread; safe to
    /// call on the main thread. Reports that fail to upload are retried on the
    /// next launch.
    public static func uploadPendingReports() {
        guard let uploadURL, let apiKey else { return }
        let reports = pendingReportsForUpload()
        guard !reports.isEmpty else { return }
        Task.detached(priority: .utility) {
            await upload(reports: reports, to: uploadURL, apiKey: apiKey)
        }
    }

    /// Returns crash reports that were written to disk during previous runs
    /// and have not yet been sent to the Owlse desktop app. Sorted oldest-first.
    public static func pendingReports() -> [LoggerStore.Event.CrashReport] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: crashDirectory, includingPropertiesForKeys: [.creationDateKey]
        ) else { return [] }
        return contents
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> LoggerStore.Event.CrashReport? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(LoggerStore.Event.CrashReport.self, from: data)
            }
            .sorted { $0.crashedAt < $1.crashedAt }
    }

    /// Removes the on-disk crash report with the given ID after it has been
    /// forwarded to the Owlse desktop app via Bonjour.
    public static func markSent(reportID: UUID) {
        let url = crashDirectory.appendingPathComponent("\(reportID.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - HTTP upload

    private static func pendingReportsForUpload() -> [LoggerStore.Event.CrashReport] {
        let uploaded = Set(
            (UserDefaults.standard.array(forKey: uploadedIDsKey) as? [String]) ?? []
        )
        return pendingReports().filter { !uploaded.contains($0.id.uuidString) }
    }

    private static func upload(
        reports: [LoggerStore.Event.CrashReport],
        to url: URL,
        apiKey: String
    ) async {
        var uploadedIDs = Set(
            (UserDefaults.standard.array(forKey: uploadedIDsKey) as? [String]) ?? []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        for report in reports {
            struct Envelope: Encodable {
                let apiKey: String
                let report: LoggerStore.Event.CrashReport
            }
            guard let body = try? encoder.encode(Envelope(apiKey: apiKey, report: report)) else {
                continue
            }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("OwlseSDK/1.0", forHTTPHeaderField: "User-Agent")
            request.httpBody = body

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    uploadedIDs.insert(report.id.uuidString)
                }
            } catch {
                // Will retry on next launch
            }
        }
        UserDefaults.standard.set(Array(uploadedIDs), forKey: uploadedIDsKey)
    }

    // MARK: - Internal

    private static let installOnce: Void = {
        createCrashDirectoryIfNeeded()
        NSSetUncaughtExceptionHandler(handleUncaughtException)
        for sig in [SIGABRT, SIGILL, SIGBUS, SIGSEGV, SIGFPE] {
            signal(sig, handleSignal)
        }
    }()

    private static let crashDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("com.owlse.crashes", isDirectory: true)
    }()

    private static func createCrashDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(at: crashDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Handlers

    // Handles Objective-C exceptions — covers most Swift runtime failures
    // (out-of-bounds, force-unwrap, precondition, etc.) because they are
    // bridged to NSException before termination.
    private static let handleUncaughtException: @convention(c) (NSException) -> Void = { exception in
        let frames = exception.callStackSymbols.enumerated().map { index, symbol in
            LoggerStore.Event.CrashFrame(index: index, symbol: symbol)
        }
        let thread = LoggerStore.Event.CrashThread(
            index: 0, name: "Crashed Thread", frames: frames, isCrashed: true
        )
        let report = LoggerStore.Event.CrashReport(
            id: UUID(),
            crashedAt: Date(),
            exceptionType: exception.name.rawValue,
            exceptionReason: exception.reason ?? "(no reason)",
            signal: nil,
            threads: [thread],
            crashedThreadIndex: 0,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: nil  // DeviceInfo.current is MainActor-isolated; omit in handler
        )
        CrashReporter.save(report)
    }

    // Handles hardware faults and explicit abort(). Uses backtrace() which is
    // async-signal-safe on Darwin. JSON encoding is not technically safe here,
    // but works in practice because the allocator is never in an inconsistent
    // state at the point these signals fire. For a production-grade reporter,
    // replace with a pre-allocated binary write.
    private static let handleSignal: @convention(c) (Int32) -> Void = { sig in
        var addresses = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let count = backtrace(&addresses, 64)
        let frames = (0..<Int(count)).map { i -> LoggerStore.Event.CrashFrame in
            let addr = addresses[i].map { UInt64(UInt(bitPattern: $0)) } ?? 0
            return LoggerStore.Event.CrashFrame(index: i, address: addr)
        }
        let thread = LoggerStore.Event.CrashThread(
            index: 0, name: "Crashed Thread", frames: frames, isCrashed: true
        )
        let report = LoggerStore.Event.CrashReport(
            id: UUID(),
            crashedAt: Date(),
            exceptionType: "Signal",
            exceptionReason: signalName(sig),
            signal: signalName(sig),
            threads: [thread],
            crashedThreadIndex: 0,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: nil  // DeviceInfo.current is MainActor-isolated; omit in signal handler
        )
        CrashReporter.save(report)

        // Restore the default handler so the OS generates a proper core dump
        // and the debugger (if attached) breaks at the crash site.
        signal(sig, SIG_DFL)
        raise(sig)
    }

    // MARK: - Helpers

    private static func save(_ report: LoggerStore.Event.CrashReport) {
        guard let data = try? JSONEncoder().encode(report) else { return }
        let url = crashDirectory.appendingPathComponent("\(report.id.uuidString).json")
        try? data.write(to: url, options: .atomic)
    }

    private static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT (Abort)"
        case SIGILL:  return "SIGILL (Illegal instruction)"
        case SIGBUS:  return "SIGBUS (Bus error)"
        case SIGSEGV: return "SIGSEGV (Bad memory access)"
        case SIGFPE:  return "SIGFPE (Floating-point exception)"
        default:      return "Signal \(sig)"
        }
    }
}
