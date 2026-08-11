# Owlse

**Owlse** is a logging and network-debugging system for Apple platforms. Native, built with SwiftUI, and free.

It comes in two halves that work together:

- **The SDK** (this repo) records `URLSession` traffic and log messages inside your app, and ships a console UI you can open from any test build.
- **The Owlse desktop app** for Mac discovers your devices over the local network and streams their logs live — a full inspector on the big screen, with a timeline, mocking, HAR export, and request diffing. It's free.

<img width="1389" height="827" alt="Screenshot 2026-08-11 at 01 43 30" src="https://github.com/user-attachments/assets/2baccf34-c485-431d-916b-ac9dc0fec845" />
<img width="1393" height="830" alt="Screenshot 2026-08-11 at 01 42 28" src="https://github.com/user-attachments/assets/770a9d5a-34f9-48aa-ba2c-3c4cdbb0310b" />


## Modules

| Module | What it does |
|---|---|
| **Owlse** | Core framework — records events into a local `LoggerStore`, plus the remote-logging client and the server engine the desktop app is built on |
| **OwlseUI** | SwiftUI console views you embed in your app, so anyone with a test build can inspect and share logs |
| **OwlseProxy** | Automatic capture of all app network traffic with a single line |

## Install

Add the package in Xcode → *Add Package Dependency*, or in `Package.swift`:

```swift
.package(url: "https://github.com/debuging-life/owlse", branch: "main")
```

## Quick start

```swift
import SwiftUI
import Owlse
import OwlseProxy

@main
struct ExampleApp: App {
    init() {
        // Capture every URLSession request in the app — one line, no
        // per-session wiring. Debug builds only.
        NetworkLogger.enableProxy()

#if DEBUG
        // Stream to the Owlse desktop app: register the store with the
        // remote logger and auto-connect to the first server found on the
        // local network.
        RemoteLogger.shared.initialize(store: .shared)
        RemoteLogger.shared.isAutomaticConnectionEnabled = true
#endif
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

Remote logging needs two `Info.plist` keys — without them iOS silently blocks
Bonjour discovery and nothing ever connects:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Streams debug logs to the Owlse desktop app.</string>
<key>NSBonjourServices</key>
<array>
    <string>_owlse._tcp</string>
    <string>_pulse._tcp</string>
</array>
```

Then open the desktop app on a Mac on the same network. Your device shows up in
its sidebar within a second or two, and requests start streaming.

Prefer to pick the Mac by hand instead of auto-connecting? Leave
`isAutomaticConnectionEnabled` off and use the *Remote Logging* screen in the
in-app console — it lists every Owlse server it can see.

## The in-app console

Show it anywhere — a debug menu, a shake gesture, a hidden tab:

```swift
import OwlseUI

ConsoleView(store: .shared)
```

- **Requests and logs in one list**, grouped by session, with a live filter bar
- **Full-text search** across URLs, headers, and bodies, with search history
- **Filters** for status code, HTTP method, host, duration, request and response
  size, content type, task type, task state, response source (network vs cache),
  redirects, log level, label, and time period — plus custom saved filters
- **Request inspector**: summary, request and response headers, cookies, both
  bodies, `cURL` command, and full `URLSessionTaskMetrics` with a per-transaction
  timing breakdown
- **Body viewer** with JSON syntax highlighting, image and PDF preview, and
  in-body search
- **Share** a session as a `.owlse` store, HAR, plain text, or HTML — AirDrop
  it, attach it to a bug report, or open it on the Mac
- Runs on **iOS, tvOS, watchOS, macOS, and visionOS**

## The Owlse desktop app

A free Mac app that acts as the receiving end of remote logging. It's the same
inspector as the in-app console, but with the room to do more.

**Live devices**
- Bonjour discovery on `_owlse._tcp` and `_pulse._tcp` — it works with apps
  built on the original Pulse SDK too
- One persistent store per device, so history survives disconnects and app
  restarts; pause or resume any device's stream, and remove ones that have gone
  away
- Optional passcode; when set, connections are TLS-encrypted (PSK) and devices
  are prompted for it on first connect
- macOS notifications when a connected device hits a failed request

**Inspecting**
- Three-pane layout: devices sidebar · request list · detail
- Detail tabs — **Overview**, **Headers** (with cookies), **Body**, **Timing**,
  **cURL**
- **Metrics** view with per-transaction phase bars (queued, DNS, TCP, TLS,
  request, waiting, download), transfer sizes, protocol, and TLS details
- Response bodies render off the main thread with line numbers, in-body search,
  and a 1,000-line cap so a 40 MB JSON payload doesn't freeze the window
- Sort, pin, and search the list; filter by everything the mobile console
  filters by, from one dialog with an active-count badge

**Beyond inspecting**
- **Timeline** — a full-width waterfall on a shared time axis; overlaps show
  parallelism, gaps show stalls
- **Sockets** — WebSocket frames grouped by connection, with direction, frame
  kind, size, and pretty-printed JSON payloads
- **Compare** — pick two requests and diff them side by side, with differing
  headers highlighted
- **Mocks** — write a rule (or build one from a captured request) and push it to
  every connected device; matching requests return the canned response, with an
  optional delay, without hitting the network
- **HAR export** — hand a session to Chrome DevTools, Charles, or anyone who
  doesn't have Owlse
- **Session stats** — request counts, error rate, latency, and top hosts
- Opens shared `.owlse` and `.pulse` stores by drag and drop, double-click, or
  *Open Log Store…*
- Light and dark themes, adjustable text size, and over-the-air updates

The app is distributed as a notarized DMG — ask the Owlse team for the latest
build. Its source lives in a separate private repository; nothing in it is
required to use this SDK.

## Recording your own events

Network capture is automatic, but the store takes anything:

```swift
import Owlse

LoggerStore.shared.storeMessage(
    label: "checkout",
    level: .warning,
    message: "Retrying payment authorization",
    metadata: ["attempt": .string("2"), "orderID": .string(order.id)]
)
```

These show up in the console's **Logs** tab and stream to the desktop app with
their labels and metadata intact.

### WebSockets

`URLSessionWebSocketTask.Message` is a Swift-only enum with no Objective-C
representation, so frames can't be captured by swizzling the way requests are.
Create sockets through the wrapper instead — it mirrors the task's API, so it's
a one-line change per socket:

```swift
let socket = OwlseWebSocketTask(url: url)
socket.resume()
try await socket.send(.string(#"{"type":"subscribe"}"#))
let message = try await socket.receive()
```

Opens, closes, sends, receives, pings, and errors all land in the **Sockets**
tab. On a different socket stack (Starscream, SocketRocket, a server SDK)? Feed
Owlse directly:

```swift
WebSocketLogger.record(direction: .received, kind: .text,
                       size: payload.count, text: payload, url: url)
```

### Custom `URLSession` setups

If you'd rather not swizzle, wire the delegate up yourself:

```swift
let session = URLSession(
    configuration: .default,
    delegate: URLSessionProxyDelegate(delegate: myDelegate),
    delegateQueue: nil
)
```

### Redacting sensitive data

Requests can carry tokens and personal data you don't want in a shared store:

```swift
let logger = NetworkLogger {
    $0.sensitiveHeaders = ["Authorization", "X-Api-Key"]
    $0.sensitiveQueryItems = ["token"]
    $0.sensitiveDataFields = ["password"]
}
NetworkLogger.enableProxy(logger: logger)
```

Matched values are replaced with `<private>` before anything is written to the
store, so they never reach the desktop app or a shared `.owlse` file. Set
`isRegexEnabled` to treat those entries as patterns. The same configuration also
takes `includedHosts` / `excludedHosts` (and the URL equivalents) when you only
want to capture part of your traffic.

## Minimum requirements

| Owlse      | Swift      | Xcode       | Platforms                                        |
|------------|------------|-------------|--------------------------------------------------|
| Owlse 5.x  | Swift 5.10 | Xcode 15.4  | iOS 15, tvOS 15, watchOS 8, macOS 12, visionOS 1 |

The desktop app requires macOS 13 or later.

## License

Owlse is available under the MIT license. See [LICENSE](LICENSE.md) for more
info.

> Owlse is a free, MIT-licensed fork of [Pulse](https://github.com/kean/Pulse),
> Copyright (c) 2020–2024 Alexander Grebenyuk, renamed and maintained
> independently. Unlike upstream, the desktop app is free.
