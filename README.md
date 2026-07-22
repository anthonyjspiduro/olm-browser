# OLM Browser

OLM Browser is a native, read-only macOS utility for browsing Microsoft Outlook `.olm` archives without importing them into Outlook.

It catalogs ZIP64 OLM files in place, displays nested Outlook folders, pages through messages on demand, renders plain-text or secured HTML email, browses contact and calendar collections, and builds a resumable SQLite/FTS5 index for archive-wide mail search. The source archive is never rewritten or expanded wholesale.

## Requirements

- macOS 14 or later
- Apple Silicon for the current packaged build
- Swift Command Line Tools to build from source

The reader has been validated against a 26 GB OLM containing 83,172 messages across 64 folders, 2 contact records across 2 contact collections, and 38,179 events across 8 calendars.

## Current features

- Native three-column SwiftUI interface with fixed bottom Mail, Calendar, and Contacts navigation (`⌘1`–`⌘3`)
- Finder-launchable, ad-hoc-signed `OLM Browser.app`
- `.olm` Finder document registration and Open dialog
- Read-only ZIP64 central-directory parsing and random-access entry reads
- One persistent read-only archive descriptor with thread-safe positional reads
- Stored and raw-DEFLATE ZIP entry support through a minimal zlib bridge
- CRC-32 verification before decoded entry bytes reach messages, attachments, previews, or exports
- Aggregate unsupported-compression and encountered integrity-failure diagnostics
- Rejection of encrypted entries and bounded entry decompression
- Automatic Outlook account and folder discovery
- Expandable nested folder hierarchy
- Folder message counts and accurate unread totals after indexing
- Incremental 100-message paging with globally chronological order from the completed index
- Lightweight indexed list rows; full XML, body, and attachment parsing only for the selected message
- 25-message bounded fallback pages while an index has not completed
- Bounded eight-worker message decoding and 20-row look-ahead page prefetching
- Sender, To, CC, BCC, subject, sent/received dates, folder, message ID, attachment count, read state, and flag display
- Attachment filename, content type, and size display
- Attachment payload resolution through each message's archive reference
- Quick Look attachment preview, Save As, drag-to-Finder, and export-all
- Unique per-session temporary files with close/quit and 24-hour stale cleanup
- 256 MB per-attachment and 1 GB batch-export extraction limits
- Missing, duplicate, malformed, oversized, and corrupt attachment diagnostics
- Local inline `cid:` image resolution with separate 20 MB image and 64 MB message limits
- Plain-text message rendering with selectable text
- Secured HTML email rendering with:
  - JavaScript disabled
  - Ephemeral WebKit storage
  - Remote images and every other network resource blocked by default
  - Per-message “Load Remote Images” approval after a privacy warning
  - Exact HTTPS image-origin allowlisting derived from that message's HTML
  - Insecure HTTP images always blocked with a visible status
  - Frames, objects, forms, media, and network connections blocked
  - Navigation and popup creation blocked
  - Explicit HTTPS link opening through a privacy confirmation; WebKit navigation remains blocked
  - Referrer suppression
  - Responsive images and dark-mode support
  - An explicit HTML/Plain Text toggle
- Persistent SQLite/FTS5 search across subjects, participants, previews, bodies, and attachment names
- B-tree-indexed lightweight message-list cache for millisecond folder paging
- Search available while background indexing continues
- Resumable 250-entry index transactions
- Parallel index decoding in 32-message chunks with serialized SQLite commits
- Interactive paging priority over background indexing
- Visible search-index progress
- Disposable, archive-fingerprinted indexes in the macOS user cache
- Structured `from:`, `to:`, `cc:`, `bcc:`, `folder:`, `after:`, `before:`, and `has:attachment` filters
- 100-result search paging without a 500-result ceiling
- Optional folder-scoped search and relevance/newest/oldest sorting
- Cancelable archive opening and indexing
- Search-index rebuild, cache deletion/compaction, and cache-size reporting
- Archive entry, attachment payload, duplicate-path, CRC-failure, unsupported-compression, recovered-malformed-message, and unreadable-message diagnostics
- Explicit JSON diagnostic-report export containing aggregate health metrics only
- Message export as `.eml` (including available attachments), plain text, JSON, PDF, and CSV
- Batch export of up to 1,000 currently loaded messages with a 1 GB output limit
- Background archive opening, paging, search, and indexing
- Contact-list discovery with lazy parsing, name/company/email/phone search, native-style contact cards, labeled/copyable values, multi-selection, and individual/selected/loaded/all-matching vCard or CSV export
- Calendar discovery with lazy parsing, a navigable month grid, Today control, selected-day agenda, event detail, attendee/organizer/location/recurrence/reminder previews, multi-selection, and individual/selected/loaded/all-matching iCalendar or CSV export
- Basic daily, weekly, monthly, and yearly recurrence expansion in the visible calendar month; stored recurrence limits and end dates are honored
- Contact and calendar collections are parsed only when their section is selected and retained only in memory for the current archive session
- Standalone parser, archive-integrity, paging-performance, index-performance, attachment, export, diagnostics, structured-search, and FTS5 smoke checks
- Synthetic contact/calendar parser and vCard/CSV/iCalendar export checks
- Synthetic remote-image policy, CSP, local-CID, and per-message approval smoke checks

## Build and run

Run the development executable:

```sh
swift run
```

Build a double-clickable application bundle:

```sh
zsh Scripts/build-app.sh
```

The finished bundle is written to:

```text
dist/OLM Browser.app
```

The script creates the icon set, builds the release executable, assembles the application bundle, and applies a local ad-hoc signature.

Run the parser smoke check without XCTest or full Xcode:

```sh
swiftc Sources/OLMBrowser/Models/ArchiveModels.swift \
  Sources/OLMBrowser/Services/OLMMessageParser.swift \
  Checks/ParserSmokeCheck.swift \
  -o /tmp/olm-parser-check && /tmp/olm-parser-check
```

Run the synthetic contact/calendar recovery check:

```sh
swiftc Sources/OLMBrowser/Models/ArchiveModels.swift \
  Sources/OLMBrowser/Services/OLMItemParsers.swift \
  Sources/OLMBrowser/Services/ContactCalendarExporter.swift \
  Checks/ContactCalendarSmokeCheck.swift \
  -o /tmp/olm-contact-calendar-check && /tmp/olm-contact-calendar-check
```

Run the calendar occurrence check:

```sh
swiftc Sources/OLMBrowser/Models/ArchiveModels.swift \
  Sources/OLMBrowser/Services/CalendarOccurrenceEngine.swift \
  Checks/CalendarOccurrenceSmokeCheck.swift \
  -o /tmp/olm-calendar-occurrence-check && /tmp/olm-calendar-occurrence-check
```

## Search behavior

Full-text indexing begins after the archive folder catalog opens. Messages remain browsable while indexing runs. The index commits every 250 entries and records its next position in the same transaction, allowing interrupted indexing to resume safely.

Message XML decoding, CRC verification, and attachment-reference resolution use a bounded eight-worker pipeline. Indexing feeds that pipeline in 32-message chunks and writes completed results through the single serialized SQLite connection. Interactive folder pages and searches take priority between index chunks. Once the index is complete, folder and search pages are constructed directly from lightweight FTS metadata without reopening or parsing 100 full message XML entries. Only the selected message is hydrated with its complete headers, body, HTML, and attachment references. Before index completion, archive-backed browsing uses smaller 25-message chunks to minimize time to first content. Folder scrolling requests the next page before the visible boundary.

Search schema 6 adds a compact `message_list` table indexed by folder, date, and attachment presence. Existing schema-5 caches migrate locally once without reparsing or modifying the OLM; that first launch after upgrading can take additional time, while subsequent launches use the indexed table directly.

Search results may be incomplete until the progress indicator finishes. Queries accept free text plus `from:`, `to:`, `cc:`, `bcc:`, `folder:`, `after:YYYY-MM-DD`, `before:YYYY-MM-DD`, and `has:attachment`. Quote filter values containing spaces. Derived search data can be rebuilt or deleted and compacted without affecting the source OLM.

Search results load in 100-message pages. The message-list controls can restrict a query to the selected folder and sort by relevance, newest date, or oldest date.

Folder browsing remains available while indexing is incomplete using archive order. Once the resumable index finishes—or immediately when a complete cache already exists—the selected folder reloads in globally descending sent-date order and accurate per-folder unread totals appear. Messages without a usable date sort last with a stable archive-path tie-breaker.

The message Export menu supports EML, plain text, JSON, PDF, and CSV. “Export Loaded” in the message-list header exports only messages already loaded into the current folder or search list; it never silently loads the rest of an archive or result set. CSV batch export creates one quote-escaped table and neutralizes spreadsheet formula-leading cells, while other formats create collision-safe individual files. A batch is limited to 1,000 messages and 1 GB of generated output.

## Privacy and safety

- The OLM is opened for reading only.
- Messages and attachments are not uploaded anywhere.
- HTML email runs with JavaScript disabled.
- Remote content and tracking pixels are blocked by default for every message; displaying an HTML message does not approve or request them.
- A “Load Remote Images” button appears when the message HTML contains a remote image. It is enabled only when the HTML names one or more explicit HTTPS image origins; pressing it first presents this warning: requesting remote images can reveal the user's IP address, access time, and message-view activity to senders or trackers.
- Confirming the warning reloads only the selected message with `img-src` restricted to the exact HTTPS origins found in its image markup and image-bearing inline CSS. Redirects or nested requests to any other origin remain blocked.
- Approval exists only in memory for the current message and archive-open session. Selecting another message, reopening an archive, quitting, or pressing “Block Remote Images” removes it. Approval never extends to a sender, domain, folder, archive, or later launch.
- Insecure `http:` images are never allowlisted. The viewer reports when HTTP images remain unavailable, even after approved HTTPS images load.
- The HTML viewer uses a nonpersistent WebKit data store and a `nil` external base URL.
- JavaScript, scripts, forms and form submission, frames and iframes, objects and embeds, audio and video, WebSocket/fetch/XHR connections, workers, manifests, popup creation, link navigation, and external base URLs remain blocked after image approval. Referrer transmission is suppressed.
- Clicking an HTML link never navigates the embedded viewer. Only HTTPS URLs without embedded credentials may cross the boundary; each click requires confirmation warning that the destination can observe the user's IP address, access time, and browser activity before opening in the default browser. HTTP, `mailto:`, and other schemes remain blocked.
- Inline images are read only from resolved local attachment entries and served through a bounded, app-local WebKit scheme; unmatched CIDs remain blocked.
- Remote image documents cannot read local attachment data: attachment bytes never enter the message HTML, scripts and connections are disabled, and the only newly permitted network requests are image loads to the selected message's HTTPS origin set.
- Attachment and message exports happen only after an explicit user action.
- Contact and calendar exports happen only after an explicit user action and write only to the destination chosen by the user.
- Contact and calendar records are not added to the mail FTS cache; selected collections are decoded locally and retained in process memory only until the archive closes or the app quits.
- Diagnostic reports are exported only after an explicit user action and omit archive paths, filenames, folder names, message content, participant data, attachment names, and attachment payloads.
- Diagnostic-report schema 2 adds only aggregate CRC-failure, unsupported-compression, recovered-malformed-message, and unreadable-message counts; it does not export entry paths or CRC values.
- Search indexes remain local in the user's cache directory.
- No cloud processing service receives message or attachment data.

## Known limitations

- Embedded HTML navigation remains intentionally blocked; approved HTTPS links open outside the app.
- The internal packaged build currently targets Apple Silicon.
- A complete selected calendar is loaded before its month grid is presented so day counts and agenda results are not based on a partial page. Large collections therefore require a one-time in-memory parse when first selected; the complete 8-calendar/38,179-event validation took about 36 seconds and peaked near 533 MB on the development machine. An individual selected calendar normally requires only its share of that work. Persistent calendar indexing and detailed parse progress remain future work.
- iCalendar export preserves the normalized fields currently recognized by the parser. Complex Outlook recurrence exceptions and time-zone blobs require broader cross-version validation.
- The managed Command Line Tools installation does not include XCTest, so checks are standalone executables.

## Planned features

1. Add detailed phase/byte progress during initial archive opening.
2. Add recent archives, drag-and-drop opening, and persistent security-scoped access.
3. Add persistent calendar/contact indexing, multi-selection, date-range filters, recurrence-exception fidelity, and detailed collection parse progress.
4. Reconstruct conversations.
5. Expand accessibility, keyboard navigation, localization, and cross-version OLM testing.

## Project layout

- `Sources/OLMBrowser/Archive/` — native ZIP64 reader
- `Sources/OLMBrowser/Models/` — normalized archive and message models
- `Sources/OLMBrowser/Services/` — OLM catalog, message parser, and paging session
- `Sources/OLMBrowser/Search/` — SQLite/FTS5 index
- `Sources/OLMBrowser/Views/` — SwiftUI and secured WebKit interface
- `Sources/CZipSupport/` — raw-DEFLATE zlib bridge
- `Sources/CSQLite/` — SQLite system-module bridge
- `Checks/` — standalone smoke checks
- `AppResources/` — application metadata and icon source
- `Scripts/` — reproducible `.app` bundle builder
- `Design/ARCHITECTURE.md` — architecture and delivery notes

## Product principles

- Never modify the source OLM.
- Open large archives in place instead of expanding them wholesale.
- Make browsing available before background indexing finishes.
- Keep derived caches disposable and traceable to their source archive.
- Extract attachments only through explicit preview or export actions.
- Keep message processing local and purpose-built for archive browsing.
