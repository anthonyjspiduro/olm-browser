import SwiftUI

@main
struct OLMBrowserApp: App {
    @StateObject private var store = ArchiveStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 940, minHeight: 620)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open OLM…") {
                    store.presentOpenPanel()
                }
                .keyboardShortcut("o")

                if store.snapshot != nil {
                    Button("Close Archive") {
                        store.closeArchive()
                    }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                }
            }
        }
    }
}
