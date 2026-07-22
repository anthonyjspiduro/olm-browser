import Foundation

struct ArchiveIdentity: Equatable, Sendable {
    let url: URL
    let displayName: String
    let size: Int64
    let isPreviewData: Bool

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct MailAccount: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let address: String
}

enum FolderKind: String, Hashable, Sendable {
    case inbox
    case sent
    case drafts
    case deleted
    case archive
    case custom

    var symbolName: String {
        switch self {
        case .inbox: "tray"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .deleted: "trash"
        case .archive: "archivebox"
        case .custom: "folder"
        }
    }
}

struct MailFolder: Identifiable, Hashable, Sendable {
    let id: String
    let accountID: String
    let parentID: String?
    let name: String
    let kind: FolderKind
    let messageCount: Int
    let unreadCount: Int
}

struct MailParticipant: Identifiable, Hashable, Sendable {
    var id: String { "\(name)|\(address)" }
    let name: String
    let address: String

    var label: String { name.isEmpty ? address : name }
}

struct AttachmentSummary: Identifiable, Hashable, Sendable {
    let id: String
    let filename: String
    let byteCount: Int64
    let contentType: String

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

struct MessageSummary: Identifiable, Hashable, Sendable {
    let id: String
    let folderID: String
    let subject: String
    let sender: MailParticipant
    let recipients: [MailParticipant]
    let sentAt: Date
    let preview: String
    let body: String
    let isRead: Bool
    let isFlagged: Bool
    let attachments: [AttachmentSummary]
}

struct ArchiveSnapshot: Sendable {
    let identity: ArchiveIdentity
    let accounts: [MailAccount]
    let folders: [MailFolder]
    let messages: [MessageSummary]
}

struct MessagePage: Sendable {
    let messages: [MessageSummary]
    let nextOffset: Int
    let totalCount: Int

    var hasMore: Bool { nextOffset < totalCount }
}

struct IndexProgress: Sendable {
    let indexed: Int
    let total: Int
    let isComplete: Bool

    var fractionCompleted: Double {
        total == 0 ? 1 : Double(indexed) / Double(total)
    }
}
