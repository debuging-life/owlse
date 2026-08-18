// The MIT License (MIT)
//
// Copyright (c) 2020-2024 Alexander Grebenyuk (github.com/kean).

import Owlse
import OwlseProxy
import OwlseUI
import SwiftUI

@main
struct OwlseDemo_iOS: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            NavigationView {
                ConsoleView(store: .demo)
            }
        }
    }
}

@MainActor
private final class AppViewModel: ObservableObject {
    init() {
        // Crash reporting — install handlers as early as possible.
        // Production: reports are uploaded to the Owlse Cloudflare Worker.
        // Development: reports also stream to the Owlse desktop app over Bonjour.
        CrashReporter.configure(
            uploadURL: URL(string: "https://owlse-crash-reporter.loudowls05.workers.dev/report")!,
            apiKey: "29690c1da1ab69667187e2c4a094cafe07d68414cc171a6c"
        )
        CrashReporter.install()
        CrashReporter.uploadPendingReports()

        // This code registers the store with the `RemoteLogger` (important!)
        LoggerStore.shared = .demo

        /*
            //Disable: options -> 1. "Settings", "Get Owlse Pro", "Report Issue"
        UserDefaults.standard.set(true, forKey: "owlse-disable-support-prompts")
        UserDefaults.standard.set(true, forKey: "owlse-disable-report-issue-prompts")
        UserDefaults.standard.set(true, forKey: "owlse-disable-settings-prompts")
         */

        // Automatically connect to the first Owlse desktop app found on the
        // local network (e.g. the free Owlse app for Mac in App/).
        RemoteLogger.shared.isAutomaticConnectionEnabled = true
        RemoteLogger.shared.sendPendingCrashReports()

        // NetworkLogger.enableProxy()

        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(3)) {
            sendRequest()
        }

        // Emit a heartbeat so remote logging visibly streams in real time
        var counter = 0
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            counter += 1
            LoggerStore.shared.storeMessage(
                label: "demo", level: .info, message: "Heartbeat #\(counter)")
        }
    }
}

private func sendRequest() {
    // testClosures()
    // testSwiftConcurrency()
}

private func testClosures() {
    let session = URLSessionProxy(configuration: .default)
    let dataTask = session.dataTask(
        with: URLRequest(
            url: URL(string: "https://api.github.com/repos/octocat/Spoon-Knife/issues?per_page=2")!)
    ) { data, _, _ in
        NSLog("didFinish: \(data?.count ?? 0)")
    }
    dataTask.resume()

    let downloadTask = session.downloadTask(
        with: URLRequest(
            url: URL(string: "https://api.github.com/repos/octocat/Spoon-Knife/issues?per_page=2")!)
    ) { url, _, _ in
        NSLog("didFinish: \(String(describing: url))")
    }
    downloadTask.resume()
}

private func testSwiftConcurrency() {
    Task {
        let demoDelegate = DemoSessionDelegate()
        let session = URLSessionProxy(
            configuration: .default, delegate: demoDelegate, delegateQueue: nil)
        //        let session = URLSession(configuration: .default)

        let (data, _) = try await session.data(
            from: URL(string: "https://api.github.com/repos/octocat/Spoon-Knife/issues?per_page=2")!
        )
        NSLog("didFinish: \(data.count)")
    }

    Task {
        let session = URLSessionProxy(configuration: .default)

        let (url, _) = try await session.download(
            from: URL(
                string: "https://api.github.com/repos/octocat/Spoon-Knife/issues?per_page=2")!,
            delegate: nil)
        NSLog("didFinish: \(url)")
    }
}

private final class DemoSessionDelegate: NSObject, URLSessionDelegate, URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        NSLog("[\(dataTask.taskIdentifier)] didReceive: \(data.count)")
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        NSLog("[\(task.taskIdentifier)] didFinishCollectingMetrics: \(metrics)")
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
        NSLog("[\(task.taskIdentifier)] didCompleteWithError: \(String(describing: error))")
    }
}
