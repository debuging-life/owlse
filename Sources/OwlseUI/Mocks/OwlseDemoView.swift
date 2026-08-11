// The MIT License (MIT)
//
// Copyright (c) 2020-2026 Alexander Grebenyuk (github.com/kean).

#if DEBUG || STANDALONE_OWLSE_APP

import SwiftUI
import Owlse

/// A demo harness that shows ``ConsoleView`` backed by ``LoggerStore/mock``
/// and ``MockConsoleDelegate``. Used by the "Owlse Demo" Xcode target to
/// exercise the `OwlseUI` surface without standing up a real logger store.
///
/// Set the `OWLSE_STORE_URL` environment variable (in the "Owlse Demo"
/// scheme) to a path or `file://` URL of a `.owlse` package to open that
/// store instead of the built-in mock — useful for reproducing issues
/// against a real capture.
///
/// Additional variants (e.g. a sessions-only view, a search harness, or a
/// network-only console) can be added here as needed.
@available(iOS 18, tvOS 18, macOS 15, watchOS 11, visionOS 1, *)
public struct OwlseDemoView: View {
    public init() {}

    public var body: some View {
#if !os(macOS)
        ConsoleView(store: OwlseDemoView.store, delegate: MockConsoleDelegate.shared)
#endif
    }

    private static var store: LoggerStore {
        if let value = ProcessInfo.processInfo.environment["OWLSE_STORE_URL"],
           !value.isEmpty {
            let url = URL(string: value).flatMap { $0.scheme == nil ? nil : $0 }
                ?? URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            do {
                return try LoggerStore(storeURL: url, options: [.readonly])
            } catch {
                assertionFailure("OWLSE_STORE_URL set but failed to open \(url): \(error)")
            }
        }
        return .mock
    }
}

#endif
