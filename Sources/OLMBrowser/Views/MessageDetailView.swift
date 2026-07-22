import SwiftUI

struct MessageDetailView: View {
    @EnvironmentObject private var store: ArchiveStore

    var body: some View {
        if let message = store.selectedMessage {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    MessageHeader(message: message)

                    Divider()
                        .padding(.vertical, 18)

                    Text(message.body)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !message.attachments.isEmpty {
                        Divider()
                            .padding(.vertical, 18)
                        AttachmentStrip(attachments: message.attachments)
                    }
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
            }
            .background(.background)
        } else {
            ContentUnavailableView(
                "No Message Selected",
                systemImage: "envelope.open",
                description: Text("Select a message to preview it.")
            )
        }
    }
}

private struct MessageHeader: View {
    let message: MessageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(message.subject)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Spacer()
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
    let attachments: [AttachmentSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Attachments")
                .font(.headline)

            ForEach(attachments) { attachment in
                HStack(spacing: 12) {
                    Image(systemName: "doc")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.filename)
                            .lineLimit(1)
                        Text(attachment.formattedSize)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Preview") {}
                        .disabled(true)
                        .help("Attachment preview arrives with the production archive reader")
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }
}
