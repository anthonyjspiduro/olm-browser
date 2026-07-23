# Architecture

## Product boundary

OLM Browser opens an OLM as a read-only data source and aims to provide complete viewing and explicit extraction coverage for the archive's recoverable record families. It does not import into Outlook, rewrite the archive, extract the entire archive, compose or send mail, synchronize accounts, or mutate Outlook records. Separate disposable caches contain only derived metadata, normalized records, search text, thumbnails, and resumable indexing state.

## Data flow

```text
Security-scoped OLM URL
        |
        v
ZIP64 central-directory reader ----> archive fingerprint
        |
        v
OLM entry catalog
   |          |             |              |
folders    messages     attachments   contacts/calendars
   |          |             |              |
   +----------+-------------+--------------+
              |
              v
      normalized domain model
          |             |
          v             v
    SwiftUI browser   SQLite/FTS5 cache
```

## Major components

### Archive access

`OLMArchiveReading` is the narrow interface between the app and archive implementations. The production reader uses ZIP64 random access, imposes decompression limits, and surfaces corrupt entries without failing the whole archive.

The first production implementation now includes a native central-directory reader with ZIP64 offsets, stored-entry reads, raw DEFLATE support through a minimal zlib bridge, encryption rejection, and per-entry expansion limits. After cataloging, it keeps one read-only file descriptor and uses thread-safe `pread` calls, avoiding a fresh open and shared seek position for every message. Every decoded stored or DEFLATE entry is checked against its central-directory CRC-32 before its bytes can reach parsing, preview, or export. A mismatch rejects only that entry; healthy entries remain independently readable. Compression methods other than stored and DEFLATE are never decoded and are counted from the central directory in archive diagnostics. It does not invoke `/usr/bin/unzip` or create a second expanded archive.

The source URL is opened only for reading. A successful explicit open creates a local bookmark used by the recent-archives list. The manager first requests security-scoped bookmark data for URLs granted through Open or Finder; because the internal ad-hoc build is not sandboxed, it can fall back to a regular persistent bookmark when a sandbox extension is unavailable. Security-scoped access, when granted, is started for that exact file, retained only for the active archive session, and released on close or termination. Derived-cache fingerprints combine the standardized archive path, file size, and modification time so a changed or moved archive does not silently reuse old data.

### Parsing

The OLM parsers turn Outlook XML into normalized accounts, folders, messages, contacts, calendar items, and attachment references. Normalized message headers include sender, To/CC/BCC, sent and received dates, message ID, read/flag state, and attachment metadata. Contact normalization retains names and nickname, company/title/department/office, manager/assistant/spouse, email addresses, phone numbers, postal addresses, websites, birthdays/anniversaries, category labels, distribution-list members, notes, and modification date. Calendar normalization retains a source-scoped internal identity, the original calendar UID for interoperable export, title, start/end, all-day/private flags, location, description, organizer, attendees, reminders, normalized time-zone labels, status, cancellation, series/recurrence identifiers, and basic recurrence metadata.

XML parsing uses `XMLParser` event callbacks rather than constructing a DOM. Mail bodies remain lazy. `Contacts.xml` and `Calendar.xml` collections are cataloged from the central directory without decoding during archive opening and parsed only when selected. A first parse reports its source, archive-read and record-parse phases, bounded decoded-byte total, recovered-record count, elapsed time, and cache-hit state; cancellation propagates into the detached parser and a partial canceled result is never cached. After a successful bounded parse, normalized records are atomically encoded into a separate binary property-list cache keyed by archive fingerprint, collection kind, and source path. A cache schema mismatch, archive size/modification change, source mismatch, decode error, or Delete Cache action causes a safe miss and reparsing; the OLM remains authoritative. Contacts retain 100-record incremental list presentation. Calendar mode deliberately loads the complete selected collection—or all collections when explicitly selected—so its month grid, chronological range view, and exports cannot silently omit events beyond an initial page.

If an entry is truncated or malformed after at least one recognized field inside an OLM message container, fields completed before the XML error are retained as a recovered message and counted separately. XML without a recognized message container and field remains unreadable; neither case stops adjacent messages from loading or indexing.

### Indexing

SQLite stores normalized metadata and indexing checkpoints. FTS5 stores searchable subject, sender, To, CC, BCC, preview, body, and attachment-name text. Index construction is incremental, cancellable, resumable, and lower priority than interactive browsing. Message archive reads, CRC checks, XML parsing, and attachment-reference normalization run through a bounded eight-worker pipeline. Indexing submits 32-message decode chunks, then performs ordered inserts through the single locked SQLite connection; interactive page/search reads pause submission of the next index chunk.

The implemented index commits every 250 entries and records the next central-directory offset in the same transaction. Search is available while indexing continues and becomes complete when the final batch commits. Cancellation rolls back an in-flight transaction rather than advancing its checkpoint. Cache filenames use a stable fingerprint of the archive path, size, and modification date.

No attachment payload is copied into the index. Derived document text is opt-in and records the exact archive entry and message identifier from which it came.

### Presentation

The primary interface is a native three-column `NavigationSplitView` with a fixed bottom Mail, Calendar, and Contacts switcher. The buttons remain outside the scrolling source list, visibly identify the active mode, and provide Command-1 through Command-3 shortcuts. In Mail, indexed folder and search rows load without message-body decoding, retain their requested order, and hydrate their full message only when selected. Unindexed fallback pages retain their requested order after parallel decoding.

Contacts use a compact avatar/name list and a native-style detail card with initials or a distribution-list symbol, title/company identity, grouped email/phone/address/date/category/note/organization/relationship/member panels, copy controls, and explicit export actions. Calendar mode loads the complete selected collection before presentation. Its upper middle pane is the selected-day agenda, its lower middle pane is event detail behind a draggable divider, and its large right pane switches between a window-scaling six-week month grid and a globally chronological list. The list accepts an inclusive date range, presets, one or all calendar sources, and optional canceled events. It exports the exact materialized occurrences in the visible range; selecting one recurrence instance exports that instance rather than the entire series.

Occurrence calculation runs away from the main actor and expands recognized daily, weekly, monthly, and yearly recurrence masters while honoring interval, occurrence-count, and end-date limits. Common Outlook recurrence aliases are normalized. An exception with matching source-scoped series and recurrence identifiers replaces its generated master occurrence; a canceled exception suppresses that occurrence. Event calculations use the normalized event time zone so local wall time remains stable across daylight-saving transitions. Common Windows zone names map to IANA identifiers, UTC aliases normalize consistently, and ISO, compact, date-only, and .NET millisecond timestamps are accepted. Unsupported proprietary relative recurrence blobs remain visible as normalized source records and are counted rather than guessed.

The three columns are:

1. Accounts/folders or contact/calendar collections
2. Filterable message/contact results, or calendar agenda above event detail
3. Message/contact detail, or the large calendar month/list workspace

HTML mail is rendered in a locked-down `WKWebView` with an ephemeral data store and no external base URL. Before loading HTML, the app extracts origins only from explicit `https:` image attributes, responsive image sets, and image-bearing inline CSS. The initial document has `img-src data:` and therefore makes no remote image request. When remote images exist, the viewer shows “Remote content blocked” beside a “Load Remote Images” button; the button is disabled with an explanation when every discovered image is insecure HTTP. The confirmation boundary for an enabled button warns that a request can reveal the user's IP address, access time, and message-view activity to senders or trackers.

Confirmation creates an in-memory approval keyed to the archive-open session, folder, and selected message. The document is then rebuilt with `img-src data:` plus only the sorted, exact HTTPS origins discovered in that message. Approval is cleared when selection changes, the archive is reopened, the app quits, or “Block Remote Images” is pressed; it never trusts a sender, domain, folder, archive, redirect target, or future launch. `http:` image URLs are counted but never admitted, and a visible “HTTP images remain blocked” status remains after HTTPS approval.

The CSP is placed before all message markup and continues to set `default-src`, `script-src`, `frame-src`, `child-src`, `media-src`, `connect-src`, `object-src`, `base-uri`, `form-action`, `manifest-src`, and `worker-src` to `'none'` as applicable. JavaScript is also disabled in WebKit preferences; form submission, popup creation, and all link navigation are intercepted; and the document sets `no-referrer`. Thus image approval does not enable forms, frames/iframes, objects/embeds, audio/video, WebSocket/fetch/XHR, workers, external base URLs, navigation, or referrer transmission. A user-activated link is canceled inside WebKit and may only be handed to the default browser after an explicit privacy confirmation; the boundary accepts credential-free HTTPS URLs and rejects HTTP, `mailto:`, and other schemes.

Plain text remains available as a fallback. Resolved inline image attachments are bounded, read from the archive, and mapped from `cid:` references to opaque URLs served by an in-memory `WKURLSchemeHandler`. Attachment bytes never enter the message HTML, and neither archive paths nor attachment URLs are exposed to the document. Unmatched CIDs remain blocked. The app-local scheme is admitted only by `img-src`; remote content cannot inspect its responses because scripts and connections stay disabled.

### Attachments

Attachment metadata is resolved lazily from `OPFAttachmentURL` to an exact central-directory entry under the parent message folder's `com.microsoft.__Attachments` namespace. Empty, escaping, missing, duplicate, directory, and oversized references remain unavailable and carry a visible diagnostic.

Previewing creates a UUID-isolated temporary file and invokes Quick Look. Drag-to-Finder uses a promised temporary representation. Save As and export-all write only to an explicit destination, preserve the displayed original filename subject to filesystem-safe leaf-name normalization, avoid batch filename collisions, and never overwrite during batch export. Per-file extraction is limited to 256 MB and a message batch to 1 GB. Session files are removed on archive close or application termination; abandoned sessions older than 24 hours are removed at startup.

### Search query path

Schema 6 keeps full-text content in FTS5 and mirrors only entry path, folder, sent timestamp, subject, sender label, preview, attachment presence, and read state into a compact `message_list` table. B-tree indexes cover folder/date paging, global date order, and attachment/date filtering. Existing schema-5 caches migrate into this table once using local derived FTS data, without reparsing or modifying the OLM. New indexes populate both stores in the same 250-message transaction, so their checkpoint and completeness cannot diverge. Outlook numeric booleans, including scientific `0E0`/`1E0` encodings, are normalized during parsing. Once complete, grouped `is_read` counts become the authoritative folder unread totals and folder pages use a global `sent_at DESC, entry_path ASC` order. These pages return lightweight list records directly from SQLite; selecting a record uses its private entry path to hydrate exactly one complete message from the read-only archive. The entry path is not included in message or diagnostic exports. Before completion, 25-message archive-order fallback paging remains available and unread badges stay hidden rather than displaying provisional totals. Structured filters that need only folder/date/attachment metadata use `message_list`; free text and participant filters use FTS5 and resolve their result paths through the lightweight table. Indexed results are counted and returned in 100-message pages with relevance or date ordering.

### Operations and export

Archive opening and indexing run in cancelable tasks. Opening reports ZIP64-directory reading, in-memory entry scanning, and Outlook cataloging phases, with entry progress and the number of bytes read for bounded ZIP structures relative to total archive size. The operations panel reports central-directory, message, attachment, duplicate-path, CRC-failure, unsupported-compression, recovered-malformed-message, unreadable-message, index-progress, combined mail/item cache-size counts, and aggregate contact/calendar recovery health. Item diagnostics include parsed/failed collection counts, missing core fields, recovered field coverage, distribution-list membership, recurrence/cancellation/exception/time-zone counts, and unsupported normalized recurrence patterns. Unsupported compression is known immediately from the central directory; CRC failures are recorded only when a bounded read of that entry is attempted. Rebuild clears the mail checkpoint and resumes indexing; Delete Cache removes and compacts mail rows and deletes parsed contact/calendar cache files.

Diagnostic-report export is an explicit local Save action. Schema version 3 contains only aggregate archive size, account/folder/message/attachment/duplicate/unreadable/recovered-malformed/CRC-failure/unsupported-compression counts, aggregate contact/calendar recovery metrics, search-index progress, cache size, generation time, and privacy declarations. It never includes the archive path or filename, account/folder/source names, message/contact/calendar identifiers or content, participants, contact values, attachment names, payloads, CRC values, or cache contents.

Message export is explicit and local. Plain-text, JSON, PDF, and CSV exports include normalized headers and body content. PDF generation uses local Core Graphics/Core Text layout and never renders remote HTML. CSV follows RFC-style quote escaping and prefixes spreadsheet formula-leading cells with an apostrophe. RFC 822 `.eml` export preserves participant/message headers, creates multipart plain/HTML content, and includes only resolved, size-bounded attachments.

Batch export operates only on messages already loaded in the active folder or search list. CSV produces one atomic table; EML, text, JSON, and PDF use a temporary staging directory followed by collision-safe copies to the chosen folder. The batch never overwrites existing files, is capped at 1,000 messages and 1 GB of generated output, and does not broaden attachment extraction limits.

Contact export writes folded RFC-style vCard 4.0 or quote-escaped CSV, including normalized postal addresses, birthdays/anniversaries, websites, organizational/relationship fields, and distribution-list members. Calendar export writes folded iCalendar 2.0 or quote-escaped CSV, including normalized attendees, reminders, privacy/cancellation state, recurrence rules, and `RECURRENCE-ID` when the Outlook pattern maps safely. Calendar range export materializes the exact occurrences intersecting the chosen range rather than leaking a recurrence master beyond that range. Exports can contain one record, a multi-selection, the records already loaded in the list, the visible calendar range, or—through a separately labeled action—all records matching the current collection and search. All writes require an explicit Save action; an entire collection is never expanded as a side effect of exporting a smaller visible selection.

## Performance goals

- Show archive identity and folder skeleton within five seconds when the central directory is healthy.
- Keep the interface responsive while cataloging 250,000 or more entries.
- Keep mail browsing and indexing memory bounded independently of total archive size.
- Bound any decoded contact/calendar collection to 512 MB and reuse its disposable normalized cache after the first successful parse.
- Resume indexing after quit, sleep, or cancellation.
- Return indexed metadata searches within 200 ms on typical hardware.

## Failure model

A malformed message, attachment, or folder must be isolated as an entry-level diagnostic. CRC mismatches and unsupported compression reject only the affected entry. Completed fields from a partially malformed OLM message may be recovered, clearly counted apart from fully parsed and unreadable entries. The app preserves all successfully browsable content and offers a privacy-preserving aggregate diagnostic report. Disk exhaustion pauses indexing without compromising the source archive.

## Delivery phases

1. Native interaction shell and normalized domain boundary.
2. ZIP64 entry catalog and archive diagnostics.
3. Folder/message XML parsing and lazy body loading.
4. Attachment preview/export and SQLite/FTS5 search.
5. Contact/calendar browsing and recovery export.
6. Persistent item caching, recurrence-exception recovery, recent archives, and detailed opening progress.
7. Chronological calendar range viewing/export, distribution lists and richer contacts, item parse progress, aggregate item diagnostics, and broader recurrence/time-zone normalization.
8. Dedicated day/week calendar layouts, remaining OLM record-family viewers/exporters, broader proprietary field recovery, and conversation reconstruction.
