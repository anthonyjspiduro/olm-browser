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
                    if let fraction = store.openProgress?.fractionCompleted {
                        ProgressView(value: fraction)
                            .frame(width: 320)
                    } else {
                        ProgressView()
                            .controlSize(.large)
                    }
                    Text(store.openProgress?.phase ?? "Opening archive…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let progress = store.openProgress {
                        if progress.totalUnits > 0 {
                            Text("\(progress.completedUnits.formatted()) of \(progress.totalUnits.formatted()) entries")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        if progress.totalBytes > 0 {
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(progress.bytesRead), countStyle: .file)) read · \(ByteCountFormatter.string(fromByteCount: Int64(progress.totalBytes), countStyle: .file)) archive")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text("The source file remains read-only")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button("Cancel") { store.cancelOpening() }
                }
            } else {
                Button("Open OLM…") {
                    store.presentOpenPanel()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if !store.recentArchives.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent Archives")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        ForEach(store.recentArchives.prefix(5)) { archive in
                            Button {
                                store.openRecentArchive(archive)
                            } label: {
                                Label(archive.displayName, systemImage: "clock.arrow.circlepath")
                                    .lineLimit(1)
                                    .frame(maxWidth: 360, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .help(archive.url.path)
                        }
                    }
                    .padding(14)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                }
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
        .overlay(alignment: .bottom) {
            Label("You can also drop an OLM file anywhere in this window", systemImage: "arrow.down.doc")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 18)
        }
    }
}
