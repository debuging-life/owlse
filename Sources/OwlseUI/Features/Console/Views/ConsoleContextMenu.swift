// The MIT License (MIT)
//
// Copyright (c) 2020-2026 Alexander Grebenyuk (github.com/kean).

#if os(iOS) || os(macOS) || os(visionOS)

import SwiftUI
import CoreData
import Owlse
import Combine

@available(iOS 18, tvOS 18, macOS 15, watchOS 11, visionOS 1, *)
struct ConsoleContextMenu: View {
#if os(iOS) || os(visionOS)
    @Binding var editMode: EditMode
#endif

    @EnvironmentObject private var environment: ConsoleEnvironment
    @Environment(\.router) private var router

    var body: some View {
        Menu {
#if os(iOS) || os(visionOS)
            Section {
                Button(action: { editMode = .active }) {
                    Label("Select", systemImage: "checkmark.circle")
                }
            }
#endif
            Section {
                Button(action: { router.isShowingFilters = true }) {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
                Button(action: { router.isShowingSessions = true }) {
                    Label("Sessions", systemImage: "list.bullet.clipboard")
                }
            }
            Section {
                Menu {
                    ConsoleSortByMenuContent()
                } label: {
                    Label("Sort By", systemImage: "arrow.up.arrow.down")
                }
                Menu {
                    ConsoleGroupByMenuContent()
                    ConsoleRemoveGroupingButton()
                } label: {
                    Label("Group By", systemImage: "rectangle.3.group")
                }
            }
            Section {
                if !UserDefaults.standard.bool(forKey: "owlse-disable-settings-prompts") {
                    Button(action: { router.isShowingSettings = true }) {
                        Label("Settings", systemImage: "gear")
                    }
                }

                if !environment.store.isReadonly {
                    Button(role: .destructive, action: environment.removeAllLogs) {
                        Label("Remove Logs", systemImage: "trash")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
    }
}

#endif
