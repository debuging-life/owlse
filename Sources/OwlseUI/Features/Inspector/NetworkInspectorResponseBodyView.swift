// The MIT License (MIT)
//
// Copyright (c) 2020-2026 Alexander Grebenyuk (github.com/kean).

import SwiftUI
import Owlse

@available(iOS 18, tvOS 18, macOS 15, watchOS 11, visionOS 1, *)
struct NetworkInspectorResponseBodyView: View {
    let viewModel: NetworkInspectorResponseBodyViewModel

    @EnvironmentObject private var environment: ConsoleEnvironment

    @State private var didCopy = false

    var body: some View {
        contents
            .inlineNavigationTitle("Response Body")
#if os(iOS) || os(visionOS) || targetEnvironment(macCatalyst)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if let text = viewModel.copyableText {
                        Button {
                            UIPasteboard.general.string = text
                            didCopy = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) {
                                didCopy = false
                            }
                        } label: {
                            Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        }
                    }
                }
            }
#endif
    }

    @ViewBuilder
    var contents: some View {
        if viewModel.hasData, let custom = environment.delegate?.console(responseBodyViewFor: viewModel.task) {
            custom
                .onDisappear { self.viewModel.onDisappear() }
        } else if let viewModel = viewModel.fileViewModel {
            FileViewer(viewModel: viewModel)
                .onDisappear { self.viewModel.onDisappear() }
        } else if viewModel.task.type == .downloadTask {
            PlaceholderView(imageName: "arrow.down.circle", title: {
                var title = "Downloaded to a File"
                if viewModel.task.responseBodySize > 0 {
                    title = "\(ByteCountFormatter.string(fromByteCount: viewModel.task.responseBodySize))\n\(title)"
                }
                return title
            }())
        } else if viewModel.task.responseBodySize > 0 {
            PlaceholderView(imageName: "exclamationmark.circle", title: "Unavailable", subtitle: "The response body was deleted from the store to reduce its size. Increase `responseBodySizeLimit` of the store.")
        } else {
            PlaceholderView(imageName: "nosign", title: "Empty Response")
        }
    }
}

final class NetworkInspectorResponseBodyViewModel {
    private(set) lazy var fileViewModel = data.map { data in
        FileViewerViewModel(
            title: "Response Body",
            context: task.responseFileViewerContext,
            data: { data }
        )
    }

    var hasData: Bool { data != nil }

    /// The whole body as text for one-tap copying — pretty-printed when it
    /// is valid JSON.
    var copyableText: String? {
        guard let data else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            return String(data: pretty, encoding: .utf8)
        }
        return String(data: data, encoding: .utf8)
    }

    private var data: Data? {
        guard let data = task.responseBody?.data, !data.isEmpty else { return nil }
        return data
    }

    let task: NetworkTaskEntity

    init(task: NetworkTaskEntity) {
        self.task = task
    }

    func onDisappear() {
        task.responseBody?.reset()
    }
}
