import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: ArchiveStore

    var body: some View {
        Group {
            if store.snapshot == nil {
                WelcomeView()
            } else {
                BrowserView()
            }
        }
        .alert(
            "Couldn’t Open Archive",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "Unknown error")
        }
        .onOpenURL { url in
            store.open(url)
        }
    }
}

private struct BrowserView: View {
    @EnvironmentObject private var store: ArchiveStore

    var body: some View {
        NavigationSplitView {
            FolderSidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 310)
        } content: {
            MessageListView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 370, max: 520)
        } detail: {
            MessageDetailView()
        }
        .navigationTitle(store.snapshot?.identity.displayName ?? "OLM Browser")
        .searchable(
            text: $store.searchText,
            placement: .toolbar,
            prompt: "Search entire archive"
        )
        .onChange(of: store.searchText) {
            store.searchTextChanged()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // Index controls arrive with the production archive reader.
                } label: {
                    Label("Archive Information", systemImage: "info.circle")
                }
                .help("Archive information")
            }
        }
    }
}
