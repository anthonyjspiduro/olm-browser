# Architecture

## Product boundary

OLM Browser opens an OLM as a read-only data source. It does not import into Outlook, rewrite the archive, or extract the entire archive. A separate cache contains only derived metadata, search text, thumbnails, and resumable indexing state.

## Data flow

```text
Security-scoped OLM URL
        |
        v
ZIP64 central-directory reader ----> archive fingerprint
        |
        v
OLM entry catalog
   |          |             |
folders    messages     attachments
   |          |             |
   +----------+-------------+
              |
              v
      normalized domain model
          |             |
          v             v
    SwiftUI browser   SQLite/FTS5 cache
                            |
                            v
                   optional grounded AI
```

## Major components

### Archive access

`OLMArchiveReading` is the narrow interface between the app and archive implementations. The production reader uses ZIP64 random access, imposes decompression limits, and surfaces corrupt entries without failing the whole archive.

The first production implementation now includes a native central-directory reader with ZIP64 offsets, stored-entry reads, raw DEFLATE support through a minimal zlib bridge, encryption rejection, and per-entry expansion limits. It does not invoke `/usr/bin/unzip` or create a second expanded archive.

The source URL must only be opened for reading. File access is retained using a security-scoped bookmark. The archive fingerprint combines file size, modification time, and central-directory metadata so a stale index is never silently reused.

### Parsing

The OLM parser turns Outlook XML into normalized accounts, folders, messages, contacts, calendar items, and attachment references. Normalized message headers include sender, To/CC/BCC, sent and received dates, message ID, read/flag state, and attachment metadata. XML parsing is streaming rather than DOM-based. Message bodies are loaded lazily and cached under a bounded policy.

### Indexing

SQLite stores normalized metadata and indexing checkpoints. FTS5 stores searchable subject, sender, To, CC, BCC, preview, body, and attachment-name text. Index construction is incremental, cancellable, resumable, and lower priority than interactive browsing.

The implemented index commits every 250 entries and records the next central-directory offset in the same transaction. Search is available while indexing continues and becomes complete when the final batch commits. Cache filenames use a stable fingerprint of the archive path, size, and modification date.

No attachment payload is copied into the index. Derived document text is opt-in and records the exact archive entry and message identifier from which it came.

### Presentation

The primary interface is a native three-column `NavigationSplitView`:

1. Accounts and folders
2. Filterable message results
3. Message body and attachments

HTML mail is rendered in a locked-down `WKWebView` with an ephemeral data store and no external base URL. Before loading HTML, the app extracts origins only from explicit `https:` image attributes, responsive image sets, and image-bearing inline CSS. The initial document has `img-src data:` and therefore makes no remote image request. When remote images exist, the viewer shows “Remote content blocked” beside a “Load Remote Images” button; the button is disabled with an explanation when every discovered image is insecure HTTP. The confirmation boundary for an enabled button warns that a request can reveal the user's IP address, access time, and message-view activity to senders or trackers.

Confirmation creates an in-memory approval keyed to the archive-open session, folder, and selected message. The document is then rebuilt with `img-src data:` plus only the sorted, exact HTTPS origins discovered in that message. Approval is cleared when selection changes, the archive is reopened, the app quits, or “Block Remote Images” is pressed; it never trusts a sender, domain, folder, archive, redirect target, or future launch. `http:` image URLs are counted but never admitted, and a visible “HTTP images remain blocked” status remains after HTTPS approval.

The CSP is placed before all message markup and continues to set `default-src`, `script-src`, `frame-src`, `child-src`, `media-src`, `connect-src`, `object-src`, `base-uri`, `form-action`, `manifest-src`, and `worker-src` to `'none'` as applicable. JavaScript is also disabled in WebKit preferences; form submission, popup creation, and all link navigation are intercepted; and the document sets `no-referrer`. Thus image approval does not enable forms, frames/iframes, objects/embeds, audio/video, WebSocket/fetch/XHR, workers, external base URLs, navigation, or referrer transmission. A user-activated link is canceled inside WebKit and may only be handed to the default browser after an explicit privacy confirmation; the boundary accepts credential-free HTTPS URLs and rejects HTTP, `mailto:`, and other schemes.

Plain text remains available as a fallback. Resolved inline image attachments are bounded, read from the archive, and mapped from `cid:` references to opaque URLs served by an in-memory `WKURLSchemeHandler`. Attachment bytes never enter the message HTML, and neither archive paths nor attachment URLs are exposed to the document. Unmatched CIDs remain blocked. The app-local scheme is admitted only by `img-src`; remote content cannot inspect its responses because scripts and connections stay disabled.

### Attachments

Attachment metadata is resolved lazily from `OPFAttachmentURL` to an exact central-directory entry under the parent message folder's `com.microsoft.__Attachments` namespace. Empty, escaping, missing, duplicate, directory, and oversized references remain unavailable and carry a visible diagnostic.

Previewing creates a UUID-isolated temporary file and invokes Quick Look. Drag-to-Finder uses a promised temporary representation. Save As and export-all write only to an explicit destination, preserve the displayed original filename subject to filesystem-safe leaf-name normalization, avoid batch filename collisions, and never overwrite during batch export. Per-file extraction is limited to 256 MB and a message batch to 1 GB. Session files are removed on archive close or application termination; abandoned sessions older than 24 hours are removed at startup.

### Search query path

The index schema stores folder ID, sent timestamp, attachment presence, and read state as unindexed FTS columns beside separate searchable sender, To, CC, and BCC fields. Schema version 5 discards only an older derived FTS table, resets its checkpoint, and resumes in 250-message transactions. Outlook numeric booleans, including scientific `0E0`/`1E0` encodings, are normalized during parsing. Once complete, grouped `is_read` counts become the authoritative folder unread totals and folder pages use a global `sent_at DESC, entry_path ASC` order. Before completion, archive-order paging remains available and unread badges stay hidden rather than displaying provisional totals. Structured `from:`, `to:`, `cc:`, `bcc:`, `folder:`, date, and attachment filter values are bound SQLite parameters; free terms alone become an escaped FTS expression. Results are counted and returned in 100-message pages with relevance or date ordering.

### Operations and export

Archive opening and indexing run in cancelable tasks. The operations panel reports central-directory, message, attachment, duplicate-path, unreadable-message, index-progress, and cache-size counts. Rebuild clears the checkpoint and resumes indexing; Delete Cache removes indexed rows and compacts the disposable database.

Diagnostic-report export is an explicit local Save action. The versioned JSON report contains only aggregate archive size, account/folder/message/attachment/duplicate/unreadable counts, search-index progress, cache size, generation time, and privacy declarations. It never includes the archive path or filename, account/folder names, message identifiers or content, participants, attachment names, payloads, or cache contents.

Message export is explicit and local. Plain-text, JSON, PDF, and CSV exports include normalized headers and body content. PDF generation uses local Core Graphics/Core Text layout and never renders remote HTML. CSV follows RFC-style quote escaping and prefixes spreadsheet formula-leading cells with an apostrophe. RFC 822 `.eml` export preserves participant/message headers, creates multipart plain/HTML content, and includes only resolved, size-bounded attachments.

Batch export operates only on messages already loaded in the active folder or search list. CSV produces one atomic table; EML, text, JSON, and PDF use a temporary staging directory followed by collision-safe copies to the chosen folder. The batch never overwrites existing files, is capped at 1,000 messages and 1 GB of generated output, and does not broaden attachment extraction limits.

### AI boundary

AI features operate on an explicit selection or query result set. Every generated claim carries source message identifiers. The app supports a local-only mode; cloud requests require a visible provider configuration and a preview of the data scope.

## Performance goals

- Show archive identity and folder skeleton within five seconds when the central directory is healthy.
- Keep the interface responsive while cataloging 250,000 or more entries.
- Use bounded memory independent of total archive size.
- Resume indexing after quit, sleep, or cancellation.
- Return indexed metadata searches within 200 ms on typical hardware.

## Failure model

A malformed message, attachment, or folder must be isolated as an entry-level diagnostic. The app preserves all successfully browsable content and offers a privacy-preserving aggregate diagnostic report. Disk exhaustion pauses indexing without compromising the source archive.

## Delivery phases

1. Native interaction shell and normalized domain boundary.
2. ZIP64 entry catalog and archive diagnostics.
3. Folder/message XML parsing and lazy body loading.
4. Attachment preview/export and SQLite/FTS5 search.
5. Contacts, calendars, conversation reconstruction, and optional AI.
