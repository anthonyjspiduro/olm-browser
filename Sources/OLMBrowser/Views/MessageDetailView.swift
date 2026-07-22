import SwiftUI

struct MessageDetailView: View {
    @EnvironmentObject private var store: ArchiveStore
    @State private var bodyMode: BodyMode = .html

    var body: some View {
        if let message = store.selectedMessage {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    MessageHeader(message: message)

                    Divider()
                        .padding(.vertical, 18)

                    if message.htmlBody != nil {
                        HStack {
                            Picker("Message body", selection: $bodyMode) {
                                Text("HTML").tag(BodyMode.html)
                                Text("Plain Text").tag(BodyMode.plainText)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 190)
                            Spacer()
                            if bodyMode == .html {
                                Label("Remote content blocked", systemImage: "shield.checkered")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.bottom, 12)
                    }

                    if bodyMode == .html, let html = message.htmlBody {
                        HTMLMessageView(html: html, inlineImages: store.inlineImages)
                            .id(message.id)
                            .frame(minHeight: 480)
                    } else {
                        Text(message.body)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !message.attachments.isEmpty {
                        Divider()
                            .padding(.vertical, 18)
                        AttachmentStrip(message: message)
                    }
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
            }
            .background(.background)
            .onChange(of: message.id) {
                bodyMode = message.htmlBody == nil ? .plainText : .html
            }
            .task(id: message.id) {
                store.loadInlineImages(for: message)
            }
        } else {
            ContentUnavailableView(
                "No Message Selected",
                systemImage: "envelope.open",
                description: Text("Select a message to preview it.")
            )
        }
    }
}

private enum BodyMode: Hashable {
    case html
    case plainText
}

private struct MessageHeader: View {
    @EnvironmentObject private var store: ArchiveStore
    let message: MessageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(message.subject)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Spacer()
                Menu("Export") {
                    ForEach(MessageExportFormat.allCases) { format in
                        Button(format.label) { store.exportMessage(message, format: format) }
                    }
                }
                if message.isFlagged {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(.orange)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                GridRow {
                    Text("From")
                        .foregroundStyle(.secondary)
                    ParticipantText(participant: message.sender)
                }
                GridRow {
                    Text("To")
                        .foregroundStyle(.secondary)
                    Text(message.recipients.map(\.label).joined(separator: ", "))
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Date")
                        .foregroundStyle(.secondary)
                    Text(message.sentAt.formatted(date: .long, time: .shortened))
                        .textSelection(.enabled)
                }
            }
            .font(.callout)
        }
    }
}

private struct ParticipantText: View {
    let participant: MailParticipant

    var body: some View {
        Text("\(participant.label) <\(participant.address)>")
            .textSelection(.enabled)
    }
}

private struct AttachmentStrip: View {
    @EnvironmentObject private var store: ArchiveStore
    let message: MessageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Attachments").font(.headline)
                Spacer()
                Button("Export All…") { store.exportAllAttachments(from: message) }
                    .disabled(!message.attachments.contains(where: \.isAvailable))
            }

            ForEach(message.attachments) { attachment in
                HStack(spacing: 12) {
                    Image(systemName: "doc")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.filename)
                            .lineLimit(1)
                        Text("\(attachment.formattedSize) · \(attachment.contentType)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let diagnostic = attachment.diagnostic {
                            Label(diagnostic.description, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button("Preview") { store.previewAttachment(attachment) }
                        .disabled(!attachment.isAvailable)
                    Button("Save As…") { store.saveAttachment(attachment) }
                        .disabled(!attachment.isAvailable)
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                .onDrag { store.attachmentDragProvider(attachment) }
            }
        }
    }
}
