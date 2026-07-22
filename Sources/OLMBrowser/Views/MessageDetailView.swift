import SwiftUI

struct MessageDetailView: View {
    @EnvironmentObject private var store: ArchiveStore
    @State private var bodyMode: BodyMode = .html
    @State private var remoteImageApproval = RemoteImageApprovalState()
    @State private var pendingRemoteImageApproval: MessageRemoteContentIdentity?
    @State private var showingRemoteImageWarning = false

    var body: some View {
        if let message = store.selectedMessage {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    MessageHeader(message: message)

                    Divider()
                        .padding(.vertical, 18)

                    if !message.isFullyLoaded {
                        ProgressView("Loading message…")
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        if message.htmlBody != nil {
                            HStack(spacing: 10) {
                                Picker("Message body", selection: $bodyMode) {
                                    Text("HTML").tag(BodyMode.html)
                                    Text("Plain Text").tag(BodyMode.plainText)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 190)
                                Spacer()
                                if bodyMode == .html, let html = message.htmlBody {
                                    RemoteImageControls(
                                        policy: RemoteImagePolicy.inspect(html),
                                        isApproved: remoteImageApproval.isApproved(for: remoteIdentity(message)),
                                        load: {
                                            pendingRemoteImageApproval = remoteIdentity(message)
                                            showingRemoteImageWarning = true
                                        },
                                        block: { remoteImageApproval.block() }
                                    )
                                }
                            }
                            .padding(.bottom, 12)
                        }

                        if bodyMode == .html, let html = message.htmlBody {
                            let policy = RemoteImagePolicy.inspect(html)
                            HTMLMessageView(
                                html: html,
                                inlineImages: store.inlineImages,
                                allowedRemoteImageOrigins: remoteImageApproval.isApproved(for: remoteIdentity(message))
                                    ? policy.httpsOrigins
                                    : [],
                                onExternalLinkRequested: store.requestOpenExternalLink
                            )
                            .id(remoteIdentity(message))
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
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
            }
            .background(.background)
            .onChange(of: remoteIdentity(message)) {
                bodyMode = message.htmlBody == nil ? .plainText : .html
                remoteImageApproval.selectionChanged(to: remoteIdentity(message))
                pendingRemoteImageApproval = nil
                showingRemoteImageWarning = false
            }
            .task(id: remoteIdentity(message)) {
                store.loadInlineImages(for: message)
            }
            .alert("Load Remote Images?", isPresented: $showingRemoteImageWarning) {
                Button("Cancel", role: .cancel) { pendingRemoteImageApproval = nil }
                Button("Load Images") {
                    let current = remoteIdentity(message)
                    guard pendingRemoteImageApproval == current,
                          store.selectedMessage.map(remoteIdentity) == current else { return }
                    remoteImageApproval.approve(current)
                    pendingRemoteImageApproval = nil
                }
            } message: {
                Text("Requesting remote images can reveal your IP address, access time, and message-view activity to senders or trackers. Approval applies only to this message.")
            }
        } else {
            ContentUnavailableView(
                "No Message Selected",
                systemImage: "envelope.open",
                description: Text("Select a message to preview it.")
            )
        }
    }

    private func remoteIdentity(_ message: MessageSummary) -> MessageRemoteContentIdentity {
        MessageRemoteContentIdentity(
            archiveSessionID: store.archiveSessionID,
            messageID: message.id,
            folderID: message.folderID
        )
    }
}

private struct RemoteImageControls: View {
    let policy: RemoteImagePolicy
    let isApproved: Bool
    let load: () -> Void
    let block: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isApproved {
                Label("Remote HTTPS images loaded", systemImage: "checkmark.shield")
                Button("Block Remote Images", action: block)
            } else {
                Label("Remote content blocked", systemImage: "shield.checkered")
                if policy.hasRemoteImages {
                    Button("Load Remote Images", action: load)
                        .disabled(policy.httpsOrigins.isEmpty)
                        .help(policy.httpsOrigins.isEmpty
                              ? "This message contains only insecure HTTP images, which cannot be loaded."
                              : "Load HTTPS images for this message only.")
                }
            }
            if policy.insecureHTTPResourceCount > 0 {
                Label("HTTP images remain blocked", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help("Insecure HTTP images cannot be loaded.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private enum BodyMode: Hashable {
    case html
    case plainText
}

private struct MessageHeader: View {
    @EnvironmentObject private var store: ArchiveStore
    @State private var showsMoreHeaders = false
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
                .disabled(!message.isFullyLoaded)
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
                    ParticipantListText(participants: message.recipients)
                }
                if !message.ccRecipients.isEmpty {
                    GridRow {
                        Text("CC")
                            .foregroundStyle(.secondary)
                        ParticipantListText(participants: message.ccRecipients)
                    }
                }
                if !message.bccRecipients.isEmpty {
                    GridRow {
                        Text("BCC")
                            .foregroundStyle(.secondary)
                        ParticipantListText(participants: message.bccRecipients)
                    }
                }
                GridRow {
                    Text("Sent")
                        .foregroundStyle(.secondary)
                    Text(message.sentAt.formatted(date: .long, time: .shortened))
                        .textSelection(.enabled)
                }
            }
            .font(.callout)

            DisclosureGroup("More Headers", isExpanded: $showsMoreHeaders) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                    if let receivedAt = message.receivedAt {
                        GridRow {
                            Text("Received").foregroundStyle(.secondary)
                            Text(receivedAt.formatted(date: .long, time: .complete))
                                .textSelection(.enabled)
                        }
                    }
                    GridRow {
                        Text("Folder").foregroundStyle(.secondary)
                        Text(store.snapshot?.folders.first { $0.id == message.folderID }?.name ?? message.folderID)
                            .textSelection(.enabled)
                    }
                    GridRow {
                        Text("Status").foregroundStyle(.secondary)
                        Text(statusLabel)
                            .textSelection(.enabled)
                    }
                    GridRow {
                        Text("Attachments").foregroundStyle(.secondary)
                        Text(message.attachments.count, format: .number)
                    }
                    if let messageID = message.messageID {
                        GridRow {
                            Text("Message ID").foregroundStyle(.secondary)
                            Text(messageID)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                }
                .font(.caption)
                .padding(.top, 6)
            }
            .font(.callout)
        }
    }

    private var statusLabel: String {
        [message.isRead ? "Read" : "Unread", message.isFlagged ? "Flagged" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

private struct ParticipantText: View {
    let participant: MailParticipant

    var body: some View {
        Text(participant.displayLabel)
            .textSelection(.enabled)
    }
}

private struct ParticipantListText: View {
    let participants: [MailParticipant]

    var body: some View {
        Text(participants.map(\.displayLabel).joined(separator: ", "))
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
