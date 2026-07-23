import Foundation

/// Stateful read-only OLM session. Catalog construction happens once; message
/// bodies are parsed only for requested pages, search results, or indexing.
final class NativeOLMArchiveReader: OLMArchiveReading, @unchecked Sendable {
    private let stateLock = NSLock()
    private let interactiveReadCondition = NSCondition()
    private let itemParseLock = NSLock()
    private var interactiveReadCount = 0
    private var archive: ZIPArchive?
    private var catalog = Catalog()
    private var entriesByPath: [String: ZIPEntry] = [:]
    private var allEntriesByPath: [String: [ZIPEntry]] = [:]
    private var folderByEntryPath: [String: MailFolder.ID] = [:]
    private var searchIndex: OLMSearchIndex?
    private var itemCache: OLMItemCache?
    private var failedMessageEntryPaths: Set<String> = []
    private var recoveredMessageEntryPaths: Set<String> = []
    private var checksumFailureEntryPaths: Set<String> = []
    private var contactsBySource: [ArchiveItemSource.ID: [ContactRecord]] = [:]
    private var eventsBySource: [ArchiveItemSource.ID: [CalendarEventRecord]] = [:]
    private var failedContactSourceIDs: Set<ArchiveItemSource.ID> = []
    private var failedCalendarSourceIDs: Set<ArchiveItemSource.ID> = []

    func openArchive(at url: URL) throws -> ArchiveSnapshot {
        try openArchive(at: url, progress: { _ in })
    }

    func openArchive(
        at url: URL,
        progress: @escaping @Sendable (ArchiveOpenProgress) -> Void
    ) throws -> ArchiveSnapshot {
        let resourceValues = try url.resourceValues(forKeys: [
            .fileSizeKey, .isReadableKey, .contentModificationDateKey
        ])
        guard resourceValues.isReadable != false else {
            throw ArchiveReaderError.unreadableArchive
        }

        let totalFileBytes = UInt64(max(0, resourceValues.fileSize ?? 0))
        progress(.init(
            phase: "Reading ZIP64 directory", completedUnits: 0, totalUnits: 0,
            bytesRead: 0, totalBytes: totalFileBytes
        ))
        let openedArchive = try ZIPArchive(url: url) { entriesRead, totalEntries, bytesRead, totalBytes in
            progress(.init(
                phase: entriesRead == 0 ? "Reading ZIP64 directory" : "Scanning archive entries",
                completedUnits: entriesRead, totalUnits: totalEntries,
                bytesRead: bytesRead, totalBytes: totalBytes
            ))
        }
        let openedCatalog = buildCatalog(
            entries: openedArchive.entries,
            progress: progress,
            bytesRead: openedArchive.centralDirectoryReadByteCount,
            totalFileBytes: totalFileBytes
        )
        guard !openedCatalog.messageEntriesByFolder.isEmpty
                || !openedCatalog.contactSources.isEmpty
                || !openedCatalog.calendarSources.isEmpty else {
            throw ArchiveReaderError.noMessagesFound
        }

        let accounts = openedCatalog.accountAddresses.sorted().map {
            MailAccount(id: $0, displayName: $0, address: $0)
        }
        let folders = makeFolders(from: openedCatalog)
        let size = Int64(resourceValues.fileSize ?? 0)
        let openedIndex = try OLMSearchIndex(
            archiveURL: url,
            fileSize: size,
            modifiedAt: resourceValues.contentModificationDate
        )
        let openedItemCache = try OLMItemCache(
            archiveURL: url,
            fileSize: size,
            modifiedAt: resourceValues.contentModificationDate
        )

        var pathLookup: [String: ZIPEntry] = [:]
        var folderLookup: [String: MailFolder.ID] = [:]
        for (folderID, entries) in openedCatalog.messageEntriesByFolder {
            for entry in entries {
                pathLookup[entry.path] = entry
                folderLookup[entry.path] = folderID
            }
        }
        let completePathLookup = Dictionary(grouping: openedArchive.entries, by: \.path)

        stateLock.withLock {
            archive = openedArchive
            catalog = openedCatalog
            entriesByPath = pathLookup
            allEntriesByPath = completePathLookup
            folderByEntryPath = folderLookup
            searchIndex = openedIndex
            itemCache = openedItemCache
            failedMessageEntryPaths = []
            recoveredMessageEntryPaths = []
            checksumFailureEntryPaths = []
            contactsBySource = [:]
            eventsBySource = [:]
            failedContactSourceIDs = []
            failedCalendarSourceIDs = []
        }

        return ArchiveSnapshot(
            identity: ArchiveIdentity(
                url: url,
                displayName: url.lastPathComponent,
                size: size,
                isPreviewData: false
            ),
            accounts: accounts,
            folders: folders,
            contactSources: openedCatalog.contactSources,
            calendarSources: openedCatalog.calendarSources,
            messages: []
        )
    }

    func loadContacts(sourceID: ArchiveItemSource.ID?, matching query: String, offset: Int, limit: Int) throws -> ContactPage {
        try loadContacts(
            sourceID: sourceID, matching: query, offset: offset, limit: limit,
            progress: { _ in }
        )
    }

    func loadContacts(
        sourceID: ArchiveItemSource.ID?,
        matching query: String,
        offset: Int,
        limit: Int,
        progress: @escaping @Sendable (ArchiveItemLoadProgress) -> Void
    ) throws -> ContactPage {
        beginInteractiveRead()
        defer { endInteractiveRead() }
        let sources = stateLock.withLock {
            catalog.contactSources.filter { sourceID == nil || $0.id == sourceID }
        }
        var records: [ContactRecord] = []
        let startedAt = Date()
        for source in sources {
            if Task.isCancelled { throw CancellationError() }
            records.append(contentsOf: try contacts(for: source, startedAt: startedAt, progress: progress))
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            records = records.filter { $0.searchText.localizedCaseInsensitiveContains(needle) }
        }
        records.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let start = min(max(0, offset), records.count)
        let end = start + min(max(1, limit), records.count - start)
        return ContactPage(records: Array(records[start..<end]), nextOffset: end, totalCount: records.count)
    }

    func loadCalendarEvents(sourceID: ArchiveItemSource.ID?, matching query: String, offset: Int, limit: Int) throws -> CalendarEventPage {
        try loadCalendarEvents(
            sourceID: sourceID, matching: query, offset: offset, limit: limit,
            progress: { _ in }
        )
    }

    func loadCalendarEvents(
        sourceID: ArchiveItemSource.ID?,
        matching query: String,
        offset: Int,
        limit: Int,
        progress: @escaping @Sendable (ArchiveItemLoadProgress) -> Void
    ) throws -> CalendarEventPage {
        beginInteractiveRead()
        defer { endInteractiveRead() }
        let sources = stateLock.withLock {
            catalog.calendarSources.filter { sourceID == nil || $0.id == sourceID }
        }
        var records: [CalendarEventRecord] = []
        let startedAt = Date()
        for source in sources {
            if Task.isCancelled { throw CancellationError() }
            records.append(contentsOf: try events(for: source, startedAt: startedAt, progress: progress))
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            records = records.filter { $0.searchText.localizedCaseInsensitiveContains(needle) }
        }
        records.sort { $0.startAt > $1.startAt }
        let start = min(max(0, offset), records.count)
        let end = start + min(max(1, limit), records.count - start)
        return CalendarEventPage(records: Array(records[start..<end]), nextOffset: end, totalCount: records.count)
    }

    func loadMessages(in folderID: MailFolder.ID, offset: Int, limit: Int) throws -> MessagePage {
        let state = stateLock.withLock {
            (archive, catalog.messageEntriesByFolder[folderID] ?? [], searchIndex)
        }
        guard let archive = state.0 else { throw ArchiveReaderError.unreadableArchive }
        beginInteractiveRead()
        defer { endInteractiveRead() }
        if let indexedPage = try state.2?.folderPageRecords(
            folderID: folderID, offset: offset, limit: limit
        ) {
            return MessagePage(
                messages: indexedPage.records.map { $0.messageSummary() },
                nextOffset: indexedPage.nextOffset,
                totalCount: indexedPage.totalCount
            )
        }
        let orderedEntries = Array(state.1.reversed())
        let start = min(max(0, offset), orderedEntries.count)
        let fallbackLimit = min(max(1, limit), Self.unindexedInteractivePageSize)
        let end = min(start + fallbackLimit, orderedEntries.count)
        var messages = parseConcurrently(
            entries: Array(orderedEntries[start..<end]), folderID: folderID, archive: archive
        )
        messages.sort { $0.sentAt > $1.sentAt }
        return MessagePage(messages: messages, nextOffset: end, totalCount: orderedEntries.count)
    }

    func buildSearchIndex(progress: @escaping @Sendable (IndexProgress) -> Void) throws {
        let state = stateLock.withLock { (archive, catalog, searchIndex) }
        guard let archive = state.0, let index = state.2 else {
            throw ArchiveReaderError.unreadableArchive
        }

        let work = state.1.messageEntriesByFolder.keys.sorted().flatMap { folderID in
            state.1.messageEntriesByFolder[folderID, default: []].map { (folderID, $0) }
        }
        var offset = min(index.nextEntryOffset, work.count)
        if index.isComplete {
            progress(IndexProgress(indexed: work.count, total: work.count, isComplete: true, failed: stateLock.withLock { failedMessageEntryPaths.count }))
            return
        }

        let batchSize = 250
        while offset < work.count {
            if Task.isCancelled { return }
            let end = min(offset + batchSize, work.count)
            try index.beginBatch()
            do {
                var chunkStart = offset
                while chunkStart < end {
                    waitForInteractiveReadsToFinish()
                    if Task.isCancelled {
                        index.rollbackBatch()
                        return
                    }
                    let chunkEnd = min(chunkStart + Self.indexDecodeChunkSize, end)
                    let chunkWork = work[chunkStart..<chunkEnd].map { folderID, entry in
                        (entry, folderID)
                    }
                    let parsed = parseConcurrentlyResults(work: chunkWork, archive: archive)
                    if Task.isCancelled {
                        index.rollbackBatch()
                        return
                    }
                    for (position, message) in parsed.enumerated() {
                        if let message {
                            try index.insert(message, entryPath: chunkWork[position].0.path)
                        }
                    }
                    chunkStart = chunkEnd
                }
                try index.commitBatch(nextOffset: end, complete: end == work.count)
            } catch {
                index.rollbackBatch()
                throw error
            }
            offset = end
            progress(IndexProgress(indexed: offset, total: work.count, isComplete: offset == work.count, failed: stateLock.withLock { failedMessageEntryPaths.count }))
        }
    }

    func searchMessages(
        matching query: String,
        folderID: MailFolder.ID?,
        offset: Int,
        limit: Int,
        sort: SearchSort
    ) throws -> MessagePage {
        let state = stateLock.withLock { (archive, searchIndex) }
        guard state.0 != nil, let index = state.1 else {
            return MessagePage(messages: [], nextOffset: 0, totalCount: 0)
        }
        beginInteractiveRead()
        defer { endInteractiveRead() }
        let page = try index.searchRecords(
            matching: query, folderID: folderID, offset: offset, limit: limit, sort: sort
        )
        let messages = page.records.map { $0.messageSummary() }
        return MessagePage(messages: messages, nextOffset: page.nextOffset, totalCount: page.totalCount)
    }

    func loadMessageDetails(for message: MessageSummary) throws -> MessageSummary {
        guard !message.isFullyLoaded else { return message }
        guard let path = message.sourceEntryPath else { return message }
        let state = stateLock.withLock {
            (archive, entriesByPath[path], folderByEntryPath[path])
        }
        guard let archive = state.0, let entry = state.1, let folderID = state.2 else {
            throw ArchiveReaderError.unreadableArchive
        }
        beginInteractiveRead()
        defer { endInteractiveRead() }
        guard let parsed = parse(
            entry: entry, folderID: folderID, archive: archive, parser: OLMMessageParser()
        ) else {
            throw ArchiveReaderError.unreadableArchive
        }
        return MessageSummary(
            id: message.id,
            folderID: parsed.folderID,
            subject: parsed.subject,
            sender: parsed.sender,
            recipients: parsed.recipients,
            ccRecipients: parsed.ccRecipients,
            bccRecipients: parsed.bccRecipients,
            messageID: parsed.messageID,
            sentAt: parsed.sentAt,
            receivedAt: parsed.receivedAt,
            preview: parsed.preview,
            body: parsed.body,
            htmlBody: parsed.htmlBody,
            isRead: parsed.isRead,
            isFlagged: parsed.isFlagged,
            attachments: parsed.attachments,
            sourceEntryPath: path,
            isFullyLoaded: true
        )
    }

    func attachmentData(for attachment: AttachmentSummary) throws -> Data {
        if let diagnostic = attachment.diagnostic {
            throw AttachmentAccessError.unavailable(diagnostic.description)
        }
        guard let path = attachment.archiveEntryPath else {
            throw AttachmentAccessError.unavailable("The attachment has no archive payload reference.")
        }
        let state = stateLock.withLock { (archive, allEntriesByPath[path] ?? []) }
        guard let archive = state.0, state.1.count == 1, let entry = state.1.first else {
            throw AttachmentAccessError.unavailable("The attachment payload is not uniquely available.")
        }
        do {
            return try archive.data(for: entry, maximumSize: Self.maximumAttachmentSize)
        } catch {
            recordArchiveReadFailure(error, entryPath: entry.path)
            throw error
        }
    }

    func operationalStatus() -> ArchiveOperationalStatus {
        stateLock.withLock {
            let entries = archive?.entries ?? []
            let parsedContacts = contactsBySource.values.flatMap { $0 }
            let parsedEvents = eventsBySource.values.flatMap { $0 }
            let itemDiagnostics = ArchiveItemDiagnosticSummary(
                parsedContactCollections: contactsBySource.count,
                failedContactCollections: failedContactSourceIDs.count,
                parsedContacts: parsedContacts.count,
                contactsMissingNames: parsedContacts.count { $0.displayName == "Unnamed Contact" },
                contactsWithEmail: parsedContacts.count { !$0.emails.isEmpty },
                contactsWithPhone: parsedContacts.count { !$0.phoneNumbers.isEmpty },
                contactsWithPostalAddress: parsedContacts.count { !$0.postalAddresses.isEmpty },
                contactDistributionLists: parsedContacts.count { $0.isDistributionList },
                parsedCalendarCollections: eventsBySource.count,
                failedCalendarCollections: failedCalendarSourceIDs.count,
                parsedCalendarEvents: parsedEvents.count,
                calendarEventsMissingDates: parsedEvents.count { $0.startAt == .distantPast },
                calendarEventsMissingTitles: parsedEvents.count { $0.title == "Untitled Event" },
                recurringCalendarEvents: parsedEvents.count { $0.recurrence != nil },
                unsupportedRecurrencePatterns: parsedEvents.count {
                    guard let recurrence = $0.recurrence else { return false }
                    return !CalendarOccurrenceEngine.supportsRecurrenceFrequency(recurrence.frequency)
                },
                recurrenceExceptions: parsedEvents.count { $0.recurrenceID != nil },
                cancelledCalendarEvents: parsedEvents.count { $0.isCancelled },
                calendarEventsWithTimeZones: parsedEvents.count { !$0.timeZoneIdentifier.isEmpty }
            )
            return ArchiveOperationalStatus(
                archiveEntries: entries.count,
                messageEntries: catalog.messageEntriesByFolder.values.reduce(0) { $0 + $1.count },
                attachmentEntries: entries.count { $0.path.contains("/com.microsoft.__Attachments/") && !$0.isDirectory },
                duplicateEntryPaths: allEntriesByPath.values.count { $0.count > 1 },
                failedMessageEntries: failedMessageEntryPaths.count,
                recoveredMalformedMessageEntries: recoveredMessageEntryPaths.count,
                checksumFailureEntries: checksumFailureEntryPaths.count,
                unsupportedCompressionEntries: entries.count {
                    $0.compressionMethod != 0 && $0.compressionMethod != 8
                },
                cacheByteCount: (searchIndex?.cacheByteCount ?? 0) + (itemCache?.byteCount ?? 0),
                itemDiagnostics: itemDiagnostics
            )
        }
    }

    func folderUnreadCounts() -> [MailFolder.ID: Int]? {
        try? stateLock.withLock { try searchIndex?.unreadCountsByFolder() }
    }

    func resetSearchIndex() throws {
        guard let index = stateLock.withLock({ searchIndex }) else { throw ArchiveReaderError.unreadableArchive }
        try index.reset(compact: false)
    }

    func deleteSearchCache() throws {
        let caches = stateLock.withLock { (searchIndex, itemCache) }
        guard let index = caches.0 else { throw ArchiveReaderError.unreadableArchive }
        try index.reset(compact: true)
        try caches.1?.removeAll()
    }

    private func parse(
        entry: ZIPEntry,
        folderID: MailFolder.ID,
        archive: ZIPArchive,
        parser: OLMMessageParser
    ) -> MessageSummary? {
        autoreleasepool {
            let data: Data
            do {
                data = try archive.data(for: entry, maximumSize: 32 * 1_024 * 1_024)
            } catch {
                recordArchiveReadFailure(error, entryPath: entry.path)
                stateLock.withLock { _ = failedMessageEntryPaths.insert(entry.path) }
                return nil
            }
            let parsed: MessageSummary
            switch parser.parseOutcome(data: data, entryPath: entry.path, folderID: folderID) {
            case .parsed(let message):
                parsed = message
            case .recovered(let message):
                stateLock.withLock { _ = recoveredMessageEntryPaths.insert(entry.path) }
                parsed = message
            case .failed:
                stateLock.withLock { _ = failedMessageEntryPaths.insert(entry.path) }
                return nil
            }
            return resolvingAttachments(in: parsed, messageEntry: entry)
        }
    }

    private func contacts(
        for source: ArchiveItemSource,
        startedAt: Date,
        progress: @escaping @Sendable (ArchiveItemLoadProgress) -> Void
    ) throws -> [ContactRecord] {
        itemParseLock.lock()
        defer { itemParseLock.unlock() }
        if let cached = stateLock.withLock({ contactsBySource[source.id] }) {
            progress(itemProgress(
                source: source, phase: "Using loaded contacts", bytes: 0, total: 0,
                records: cached.count, startedAt: startedAt, cacheHit: true
            ))
            return cached
        }
        if let cached = stateLock.withLock({ itemCache?.contacts(for: source.id) }) {
            stateLock.withLock { contactsBySource[source.id] = cached }
            progress(itemProgress(
                source: source, phase: "Loading cached contacts", bytes: 0, total: 0,
                records: cached.count, startedAt: startedAt, cacheHit: true
            ))
            return cached
        }
        let state = stateLock.withLock { (archive, allEntriesByPath[source.entryPath]?.first) }
        guard let archive = state.0, let entry = state.1 else { throw ArchiveReaderError.unreadableArchive }
        do {
            progress(itemProgress(
                source: source, phase: "Reading contact collection", bytes: 0,
                total: entry.uncompressedSize, records: 0, startedAt: startedAt, cacheHit: false
            ))
            let data = try archive.data(for: entry, maximumSize: Self.maximumItemCollectionSize)
            let parsed = OLMContactParser().parse(data: data, source: source) { count in
                progress(self.itemProgress(
                    source: source, phase: "Parsing contacts", bytes: UInt64(data.count),
                    total: entry.uncompressedSize, records: count, startedAt: startedAt, cacheHit: false
                ))
            }
            if Task.isCancelled { throw CancellationError() }
            stateLock.withLock {
                contactsBySource[source.id] = parsed
                failedContactSourceIDs.remove(source.id)
                itemCache?.storeContacts(parsed, sourceID: source.id)
            }
            progress(itemProgress(
                source: source, phase: "Contact collection ready", bytes: UInt64(data.count),
                total: entry.uncompressedSize, records: parsed.count, startedAt: startedAt, cacheHit: false
            ))
            return parsed
        } catch {
            if !(error is CancellationError) {
                stateLock.withLock { _ = failedContactSourceIDs.insert(source.id) }
            }
            throw error
        }
    }

    private func events(
        for source: ArchiveItemSource,
        startedAt: Date,
        progress: @escaping @Sendable (ArchiveItemLoadProgress) -> Void
    ) throws -> [CalendarEventRecord] {
        itemParseLock.lock()
        defer { itemParseLock.unlock() }
        if let cached = stateLock.withLock({ eventsBySource[source.id] }) {
            progress(itemProgress(
                source: source, phase: "Using loaded calendar", bytes: 0, total: 0,
                records: cached.count, startedAt: startedAt, cacheHit: true
            ))
            return cached
        }
        if let cached = stateLock.withLock({ itemCache?.calendarEvents(for: source.id) }) {
            stateLock.withLock { eventsBySource[source.id] = cached }
            progress(itemProgress(
                source: source, phase: "Loading cached calendar", bytes: 0, total: 0,
                records: cached.count, startedAt: startedAt, cacheHit: true
            ))
            return cached
        }
        let state = stateLock.withLock { (archive, allEntriesByPath[source.entryPath]?.first) }
        guard let archive = state.0, let entry = state.1 else { throw ArchiveReaderError.unreadableArchive }
        do {
            progress(itemProgress(
                source: source, phase: "Reading calendar collection", bytes: 0,
                total: entry.uncompressedSize, records: 0, startedAt: startedAt, cacheHit: false
            ))
            let data = try archive.data(for: entry, maximumSize: Self.maximumItemCollectionSize)
            let parsed = OLMCalendarParser().parse(data: data, source: source) { count in
                progress(self.itemProgress(
                    source: source, phase: "Parsing calendar events", bytes: UInt64(data.count),
                    total: entry.uncompressedSize, records: count, startedAt: startedAt, cacheHit: false
                ))
            }
            if Task.isCancelled { throw CancellationError() }
            stateLock.withLock {
                eventsBySource[source.id] = parsed
                failedCalendarSourceIDs.remove(source.id)
                itemCache?.storeCalendarEvents(parsed, sourceID: source.id)
            }
            progress(itemProgress(
                source: source, phase: "Calendar collection ready", bytes: UInt64(data.count),
                total: entry.uncompressedSize, records: parsed.count, startedAt: startedAt, cacheHit: false
            ))
            return parsed
        } catch {
            if !(error is CancellationError) {
                stateLock.withLock { _ = failedCalendarSourceIDs.insert(source.id) }
            }
            throw error
        }
    }

    private func itemProgress(
        source: ArchiveItemSource,
        phase: String,
        bytes: UInt64,
        total: UInt64,
        records: Int,
        startedAt: Date,
        cacheHit: Bool
    ) -> ArchiveItemLoadProgress {
        ArchiveItemLoadProgress(
            kind: source.kind, sourceName: source.name, phase: phase,
            completedBytes: bytes, totalBytes: total, recordsDiscovered: records,
            startedAt: startedAt, isCacheHit: cacheHit
        )
    }

    private func parseConcurrently(
        entries: [ZIPEntry], folderID: MailFolder.ID, archive: ZIPArchive
    ) -> [MessageSummary] {
        parseConcurrently(work: entries.map { ($0, folderID) }, archive: archive)
    }

    private func parseConcurrently(
        work: [(ZIPEntry, MailFolder.ID)], archive: ZIPArchive
    ) -> [MessageSummary] {
        parseConcurrentlyResults(work: work, archive: archive).compactMap { $0 }
    }

    private func parseConcurrentlyResults(
        work: [(ZIPEntry, MailFolder.ID)], archive: ZIPArchive
    ) -> [MessageSummary?] {
        guard !work.isEmpty else { return [] }
        let state = ParallelMessageParseState(work: work)
        let workerCount = min(Self.maximumConcurrentMessageReads, work.count)
        DispatchQueue.concurrentPerform(iterations: workerCount) { _ in
            let parser = OLMMessageParser()
            while let item = state.takeNext() {
                if Task.isCancelled { return }
                let message = parse(
                    entry: item.entry,
                    folderID: item.folderID,
                    archive: archive,
                    parser: parser
                )
                state.store(message, at: item.index)
            }
        }
        return state.completedResults()
    }

    private func beginInteractiveRead() {
        interactiveReadCondition.lock()
        interactiveReadCount += 1
        interactiveReadCondition.unlock()
    }

    private func endInteractiveRead() {
        interactiveReadCondition.lock()
        interactiveReadCount -= 1
        interactiveReadCondition.broadcast()
        interactiveReadCondition.unlock()
    }

    private func waitForInteractiveReadsToFinish() {
        interactiveReadCondition.lock()
        while interactiveReadCount > 0 && !Task.isCancelled {
            _ = interactiveReadCondition.wait(until: Date(timeIntervalSinceNow: 0.1))
        }
        interactiveReadCondition.unlock()
    }

    private func recordArchiveReadFailure(_ error: Error, entryPath: String) {
        guard let zipError = error as? ZIPArchiveError else { return }
        stateLock.withLock {
            switch zipError {
            case .checksumMismatch:
                _ = checksumFailureEntryPaths.insert(entryPath)
            default:
                break
            }
        }
    }

    private func resolvingAttachments(in message: MessageSummary, messageEntry: ZIPEntry) -> MessageSummary {
        let lookup = stateLock.withLock { allEntriesByPath }
        let parent = (messageEntry.path as NSString).deletingLastPathComponent
        let allowedPrefix = parent + "/com.microsoft.__Attachments/"
        let resolved = message.attachments.map { attachment -> AttachmentSummary in
            let rawPath = attachment.archiveEntryPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let components = rawPath.split(separator: "/", omittingEmptySubsequences: false)
            let malformed = rawPath.isEmpty
                || rawPath.hasPrefix("/")
                || rawPath.contains("\\")
                || rawPath.contains("\0")
                || components.contains(".")
                || components.contains("..")
                || !rawPath.hasPrefix(allowedPrefix)
            let candidates = malformed ? [] : lookup[rawPath, default: []]
            let diagnostic: AttachmentDiagnostic?
            let resolvedPath: String?
            let actualSize: Int64
            if malformed {
                diagnostic = .malformedReference
                resolvedPath = nil
                actualSize = attachment.byteCount
            } else if candidates.isEmpty {
                diagnostic = .missingPayload
                resolvedPath = nil
                actualSize = attachment.byteCount
            } else if candidates.count > 1 {
                diagnostic = .duplicatePayload
                resolvedPath = nil
                actualSize = attachment.byteCount
            } else if let entry = candidates.first, entry.isDirectory {
                diagnostic = .malformedReference
                resolvedPath = nil
                actualSize = attachment.byteCount
            } else if let entry = candidates.first,
                      entry.compressionMethod != 0 && entry.compressionMethod != 8 {
                diagnostic = .unsupportedCompression(method: entry.compressionMethod)
                resolvedPath = nil
                actualSize = Int64(clamping: entry.uncompressedSize)
            } else if let entry = candidates.first,
                      entry.uncompressedSize > Self.maximumAttachmentSize {
                diagnostic = .oversized(limit: Int64(Self.maximumAttachmentSize))
                resolvedPath = nil
                actualSize = Int64(clamping: entry.uncompressedSize)
            } else {
                diagnostic = nil
                resolvedPath = rawPath
                actualSize = candidates.first.map { Int64(clamping: $0.uncompressedSize) } ?? attachment.byteCount
            }
            return AttachmentSummary(
                id: attachment.id,
                filename: attachment.filename,
                byteCount: actualSize,
                contentType: attachment.contentType,
                contentID: attachment.contentID,
                archiveEntryPath: resolvedPath,
                diagnostic: diagnostic
            )
        }
        return MessageSummary(
            id: message.id, folderID: message.folderID, subject: message.subject,
            sender: message.sender, recipients: message.recipients,
            ccRecipients: message.ccRecipients, bccRecipients: message.bccRecipients,
            messageID: message.messageID, sentAt: message.sentAt, receivedAt: message.receivedAt,
            preview: message.preview, body: message.body, htmlBody: message.htmlBody,
            isRead: message.isRead, isFlagged: message.isFlagged, attachments: resolved,
            sourceEntryPath: message.sourceEntryPath,
            isFullyLoaded: message.isFullyLoaded
        )
    }

    static let maximumAttachmentSize: UInt64 = 256 * 1_024 * 1_024
    static let maximumItemCollectionSize: UInt64 = 512 * 1_024 * 1_024
    static let maximumConcurrentMessageReads = 8
    static let indexDecodeChunkSize = 32
    static let unindexedInteractivePageSize = 25

    private func buildCatalog(
        entries: [ZIPEntry],
        progress: @escaping @Sendable (ArchiveOpenProgress) -> Void = { _ in },
        bytesRead: UInt64 = 0,
        totalFileBytes: UInt64 = 0
    ) -> Catalog {
        var catalog = Catalog()
        let marker = "/com.microsoft.__Messages/"
        for (index, entry) in entries.enumerated() where entry.path.hasSuffix(".xml") {
            if index.isMultiple(of: 5_000) {
                progress(.init(
                    phase: "Cataloging Outlook data",
                    completedUnits: index, totalUnits: entries.count,
                    bytesRead: bytesRead, totalBytes: totalFileBytes
                ))
            }
            if entry.path.hasSuffix("/Contacts.xml") || entry.path == "Local/Address Book/Contacts.xml" {
                let source = Self.itemSource(for: entry, kind: .contacts)
                catalog.contactSources.append(source)
                if let account = source.accountID { catalog.accountAddresses.insert(account) }
            } else if entry.path.hasSuffix("/Calendar.xml") {
                let source = Self.itemSource(for: entry, kind: .calendar)
                catalog.calendarSources.append(source)
                if let account = source.accountID { catalog.accountAddresses.insert(account) }
            }
            guard entry.path.hasPrefix("Accounts/"),
                  let markerRange = entry.path.range(of: marker),
                  entry.path[markerRange.upperBound...].lastPathComponent.hasPrefix("message_") else {
                continue
            }
            let accountStart = entry.path.index(entry.path.startIndex, offsetBy: "Accounts/".count)
            let account = String(entry.path[accountStart..<markerRange.lowerBound])
            let remainder = String(entry.path[markerRange.upperBound...])
            let components = remainder.split(separator: "/").map(String.init)
            guard components.count >= 2 else { continue }
            let folderPath = components.dropLast().joined(separator: "/")
            let folderID = Self.folderID(account: account, path: folderPath)

            catalog.accountAddresses.insert(account)
            catalog.folderPathsByAccount[account, default: []].insert(folderPath)
            catalog.messageEntriesByFolder[folderID, default: []].append(entry)

            var ancestors = folderPath.split(separator: "/").map(String.init)
            while ancestors.count > 1 {
                ancestors.removeLast()
                catalog.folderPathsByAccount[account, default: []]
                    .insert(ancestors.joined(separator: "/"))
            }
        }
        catalog.contactSources.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        catalog.calendarSources.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        progress(.init(
            phase: "Cataloging Outlook data",
            completedUnits: entries.count, totalUnits: entries.count,
            bytesRead: bytesRead, totalBytes: totalFileBytes
        ))
        return catalog
    }

    private static func itemSource(for entry: ZIPEntry, kind: ArchiveItemKind) -> ArchiveItemSource {
        let components = entry.path.split(separator: "/").map(String.init)
        let account = components.first == "Accounts" && components.count > 1 ? components[1] : nil
        let parentName = components.dropLast().last ?? (kind == .contacts ? "Contacts" : "Calendar")
        return ArchiveItemSource(
            id: entry.path, accountID: account, name: parentName,
            kind: kind, entryPath: entry.path
        )
    }

    private func makeFolders(from catalog: Catalog) -> [MailFolder] {
        var result: [MailFolder] = []
        for account in catalog.accountAddresses.sorted() {
            for path in catalog.folderPathsByAccount[account, default: []].sorted() {
                let components = path.split(separator: "/").map(String.init)
                let name = components.last ?? path
                let parentPath = components.dropLast().joined(separator: "/")
                let id = Self.folderID(account: account, path: path)
                result.append(MailFolder(
                    id: id,
                    accountID: account,
                    parentID: parentPath.isEmpty ? nil : Self.folderID(account: account, path: parentPath),
                    name: name,
                    kind: Self.folderKind(name),
                    messageCount: catalog.messageEntriesByFolder[id, default: []].count,
                    unreadCount: 0
                ))
            }
        }
        return result.sorted {
            let leftRank = Self.folderRank($0.kind)
            let rightRank = Self.folderRank($1.kind)
            return leftRank == rightRank
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : leftRank < rightRank
        }
    }

    private static func folderID(account: String, path: String) -> String { "\(account)::\(path)" }

    private static func folderKind(_ name: String) -> FolderKind {
        switch name.lowercased() {
        case "inbox": .inbox
        case "sent", "sent items": .sent
        case "drafts": .drafts
        case "deleted", "deleted items", "trash": .deleted
        case "archive": .archive
        default: .custom
        }
    }

    private static func folderRank(_ kind: FolderKind) -> Int {
        switch kind {
        case .inbox: 0
        case .sent: 1
        case .drafts: 2
        case .archive: 3
        case .deleted: 4
        case .custom: 5
        }
    }
}

private final class ParallelMessageParseState: @unchecked Sendable {
    typealias WorkItem = (entry: ZIPEntry, folderID: MailFolder.ID)

    private let lock = NSLock()
    private let work: [WorkItem]
    private var nextIndex = 0
    private var results: [MessageSummary?]

    init(work: [WorkItem]) {
        self.work = work
        self.results = Array(repeating: nil, count: work.count)
    }

    func takeNext() -> (index: Int, entry: ZIPEntry, folderID: MailFolder.ID)? {
        lock.withLock {
            guard nextIndex < work.count else { return nil }
            let index = nextIndex
            nextIndex += 1
            return (index, work[index].entry, work[index].folderID)
        }
    }

    func store(_ message: MessageSummary?, at index: Int) {
        lock.withLock { results[index] = message }
    }

    func completedResults() -> [MessageSummary?] {
        lock.withLock { results }
    }
}

private struct Catalog: Sendable {
    var accountAddresses: Set<String> = []
    var folderPathsByAccount: [String: Set<String>] = [:]
    var messageEntriesByFolder: [String: [ZIPEntry]] = [:]
    var contactSources: [ArchiveItemSource] = []
    var calendarSources: [ArchiveItemSource] = []
}

private extension String.SubSequence {
    var lastPathComponent: Substring { split(separator: "/").last ?? self }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
