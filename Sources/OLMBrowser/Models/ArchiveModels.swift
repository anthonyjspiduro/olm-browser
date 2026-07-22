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

enum AttachmentDiagnostic: Hashable, Sendable {
    case missingPayload
    case duplicatePayload
    case malformedReference
    case oversized(limit: Int64)

    var description: String {
        switch self {
        case .missingPayload: "The attachment payload is missing from the archive."
        case .duplicatePayload: "The archive contains duplicate payload entries for this attachment."
        case .malformedReference: "The attachment reference is malformed or points outside its message folder."
        case .oversized(let limit): "The attachment exceeds the \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)) extraction limit."
        }
    }
}

struct AttachmentSummary: Identifiable, Hashable, Sendable {
    let id: String
    let filename: String
    let byteCount: Int64
    let contentType: String
    let contentID: String?
    let archiveEntryPath: String?
    let diagnostic: AttachmentDiagnostic?

    init(
        id: String,
        filename: String,
        byteCount: Int64,
        contentType: String,
        contentID: String? = nil,
        archiveEntryPath: String? = nil,
        diagnostic: AttachmentDiagnostic? = nil
    ) {
        self.id = id
        self.filename = filename
        self.byteCount = byteCount
        self.contentType = contentType
        self.contentID = contentID
        self.archiveEntryPath = archiveEntryPath
        self.diagnostic = diagnostic
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    var isAvailable: Bool { archiveEntryPath != nil && diagnostic == nil }
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
    let htmlBody: String?
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

enum SearchSort: String, CaseIterable, Identifiable, Sendable {
    case relevance
    case newest
    case oldest

    var id: String { rawValue }
    var label: String {
        switch self {
        case .relevance: "Relevance"
        case .newest: "Newest First"
        case .oldest: "Oldest First"
        }
    }
}

struct IndexProgress: Sendable {
    let indexed: Int
    let total: Int
    let isComplete: Bool
    let failed: Int

    init(indexed: Int, total: Int, isComplete: Bool, failed: Int = 0) {
        self.indexed = indexed
        self.total = total
        self.isComplete = isComplete
        self.failed = failed
    }

    var fractionCompleted: Double {
        total == 0 ? 1 : Double(indexed) / Double(total)
    }
}

struct ArchiveOperationalStatus: Sendable {
    let archiveEntries: Int
    let messageEntries: Int
    let attachmentEntries: Int
    let duplicateEntryPaths: Int
    let failedMessageEntries: Int
    let cacheByteCount: Int64
}
