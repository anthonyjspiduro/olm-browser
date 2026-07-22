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

enum ArchiveItemKind: String, Hashable, Sendable {
    case contacts
    case calendar
}

struct ArchiveItemSource: Identifiable, Hashable, Sendable {
    let id: String
    let accountID: String?
    let name: String
    let kind: ArchiveItemKind
    let entryPath: String
}

struct ContactEmailAddress: Identifiable, Hashable, Sendable {
    var id: String { "\(label)|\(address)" }
    let label: String
    let address: String
}

struct ContactPhoneNumber: Identifiable, Hashable, Sendable {
    var id: String { "\(label)|\(number)" }
    let label: String
    let number: String
}

struct ContactRecord: Identifiable, Hashable, Sendable {
    let id: String
    let sourceID: ArchiveItemSource.ID
    let displayName: String
    let firstName: String
    let middleName: String
    let lastName: String
    let company: String
    let jobTitle: String
    let emails: [ContactEmailAddress]
    let phoneNumbers: [ContactPhoneNumber]
    let notes: String
    let modifiedAt: Date?

    var searchText: String {
        ([displayName, firstName, middleName, lastName, company, jobTitle, notes]
            + emails.flatMap { [$0.label, $0.address] }
            + phoneNumbers.flatMap { [$0.label, $0.number] })
            .joined(separator: " ")
    }
}

struct CalendarAttendee: Identifiable, Hashable, Sendable {
    var id: String { "\(name)|\(address)|\(type)" }
    let name: String
    let address: String
    let type: String
    let status: String
    let responseRequested: Bool
}

struct CalendarRecurrence: Hashable, Sendable {
    let frequency: String
    let interval: Int
    let occurrenceCount: Int?
    let endDate: Date?
}

struct CalendarEventRecord: Identifiable, Hashable, Sendable {
    let id: String
    let sourceID: ArchiveItemSource.ID
    let title: String
    let startAt: Date
    let endAt: Date
    let location: String
    let details: String
    let organizer: String
    let attendees: [CalendarAttendee]
    let isAllDay: Bool
    let isPrivate: Bool
    let hasReminder: Bool
    let reminderMinutes: Int?
    let recurrence: CalendarRecurrence?

    var searchText: String {
        ([title, location, details, organizer]
            + attendees.flatMap { [$0.name, $0.address] })
            .joined(separator: " ")
    }
}

struct ContactPage: Sendable {
    let records: [ContactRecord]
    let nextOffset: Int
    let totalCount: Int
    var hasMore: Bool { nextOffset < totalCount }
}

struct CalendarEventPage: Sendable {
    let records: [CalendarEventRecord]
    let nextOffset: Int
    let totalCount: Int
    var hasMore: Bool { nextOffset < totalCount }
}

struct MailParticipant: Identifiable, Hashable, Sendable {
    var id: String { "\(name)|\(address)" }
    let name: String
    let address: String

    var label: String { name.isEmpty ? address : name }

    var displayLabel: String {
        if name.isEmpty { return address }
        if address.isEmpty { return name }
        return "\(name) <\(address)>"
    }
}

enum AttachmentDiagnostic: Hashable, Sendable {
    case missingPayload
    case duplicatePayload
    case malformedReference
    case oversized(limit: Int64)
    case unsupportedCompression(method: UInt16)

    var description: String {
        switch self {
        case .missingPayload: "The attachment payload is missing from the archive."
        case .duplicatePayload: "The archive contains duplicate payload entries for this attachment."
        case .malformedReference: "The attachment reference is malformed or points outside its message folder."
        case .oversized(let limit): "The attachment exceeds the \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)) extraction limit."
        case .unsupportedCompression(let method): "The attachment uses unsupported ZIP compression method \(method)."
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
    let ccRecipients: [MailParticipant]
    let bccRecipients: [MailParticipant]
    let messageID: String?
    let sentAt: Date
    let receivedAt: Date?
    let preview: String
    let body: String
    let htmlBody: String?
    let isRead: Bool
    let isFlagged: Bool
    let attachments: [AttachmentSummary]
    let sourceEntryPath: String?
    let isFullyLoaded: Bool

    init(
        id: String,
        folderID: String,
        subject: String,
        sender: MailParticipant,
        recipients: [MailParticipant],
        ccRecipients: [MailParticipant],
        bccRecipients: [MailParticipant],
        messageID: String?,
        sentAt: Date,
        receivedAt: Date?,
        preview: String,
        body: String,
        htmlBody: String?,
        isRead: Bool,
        isFlagged: Bool,
        attachments: [AttachmentSummary],
        sourceEntryPath: String? = nil,
        isFullyLoaded: Bool = true
    ) {
        self.id = id
        self.folderID = folderID
        self.subject = subject
        self.sender = sender
        self.recipients = recipients
        self.ccRecipients = ccRecipients
        self.bccRecipients = bccRecipients
        self.messageID = messageID
        self.sentAt = sentAt
        self.receivedAt = receivedAt
        self.preview = preview
        self.body = body
        self.htmlBody = htmlBody
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.attachments = attachments
        self.sourceEntryPath = sourceEntryPath
        self.isFullyLoaded = isFullyLoaded
    }
}

struct ArchiveSnapshot: Sendable {
    let identity: ArchiveIdentity
    let accounts: [MailAccount]
    let folders: [MailFolder]
    let contactSources: [ArchiveItemSource]
    let calendarSources: [ArchiveItemSource]
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
    let recoveredMalformedMessageEntries: Int
    let checksumFailureEntries: Int
    let unsupportedCompressionEntries: Int
    let cacheByteCount: Int64
}
