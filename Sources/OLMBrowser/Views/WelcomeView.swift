import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var store: ArchiveStore

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "archivebox")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Browse Outlook Archives")
                    .font(.largeTitle.weight(.semibold))
                Text("Open an OLM in place. Your archive stays unchanged.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            if store.isOpening {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Cataloging archive…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("The source file remains read-only")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Button("Open OLM…") {
                    store.presentOpenPanel()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            HStack(spacing: 22) {
                Label("Read-only", systemImage: "lock")
                Label("No Outlook import", systemImage: "arrow.down.doc")
                Label("Local index", systemImage: "internaldrive")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
