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

The OLM parser turns Outlook XML into normalized accounts, folders, messages, contacts, calendar items, and attachment references. XML parsing is streaming rather than DOM-based. Message bodies are loaded lazily and cached under a bounded policy.

### Indexing

SQLite stores normalized metadata and indexing checkpoints. FTS5 stores searchable subject, participant, preview, body, and attachment-name text. Index construction is incremental, cancellable, resumable, and lower priority than interactive browsing.

The implemented index commits every 250 entries and records the next central-directory offset in the same transaction. Search is available while indexing continues and becomes complete when the final batch commits. Cache filenames use a stable fingerprint of the archive path, size, and modification date.

No attachment payload is copied into the index. Derived document text is opt-in and records the exact archive entry and message identifier from which it came.

### Presentation

The primary interface is a native three-column `NavigationSplitView`:

1. Accounts and folders
2. Filterable message results
3. Message body and attachments

HTML mail is rendered in a locked-down `WKWebView`: scripts disabled, remote resources blocked, and navigation intercepted. Plain text remains available as a fallback. Resolved inline image attachments are bounded, read from the archive, and substituted as `data:` image URLs; the CSP continues to reject HTTP(S), scripts, frames, forms, media, objects, and connections.

### Attachments

Attachment metadata is resolved lazily from `OPFAttachmentURL` to an exact central-directory entry under the parent message folder's `com.microsoft.__Attachments` namespace. Empty, escaping, missing, duplicate, directory, and oversized references remain unavailable and carry a visible diagnostic.

Previewing creates a UUID-isolated temporary file and invokes Quick Look. Drag-to-Finder uses a promised temporary representation. Save As and export-all write only to an explicit destination, preserve the displayed original filename subject to filesystem-safe leaf-name normalization, avoid batch filename collisions, and never overwrite during batch export. Per-file extraction is limited to 256 MB and a message batch to 1 GB. Session files are removed on archive close or application termination; abandoned sessions older than 24 hours are removed at startup.

### Search query path

The index schema stores folder ID, sent timestamp, and attachment presence as unindexed FTS columns beside searchable text. A versioned schema migration discards the older derived index and resumes in 250-message transactions. Filter values are bound SQLite parameters; free terms alone become an escaped FTS expression. Results are counted and returned in 100-message pages with relevance or date ordering.

### Operations and export

Archive opening and indexing run in cancelable tasks. The operations panel reports central-directory, message, attachment, duplicate-path, unreadable-message, index-progress, and cache-size counts. Rebuild clears the checkpoint and resumes indexing; Delete Cache removes indexed rows and compacts the disposable database.

Message export is explicit and local. Plain-text and JSON exports include normalized message fields. RFC 822 `.eml` export creates multipart plain/HTML content and includes only resolved, size-bounded attachments.

### AI boundary

AI features operate on an explicit selection or query result set. Every generated claim carries source message identifiers. The app supports a local-only mode; cloud requests require a visible provider configuration and a preview of the data scope.

## Performance goals

- Show archive identity and folder skeleton within five seconds when the central directory is healthy.
- Keep the interface responsive while cataloging 250,000 or more entries.
- Use bounded memory independent of total archive size.
- Resume indexing after quit, sleep, or cancellation.
- Return indexed metadata searches within 200 ms on typical hardware.

## Failure model

A malformed message, attachment, or folder must be isolated as an entry-level diagnostic. The app should preserve all successfully browsable content and offer an exportable diagnostic report. Disk exhaustion pauses indexing without compromising the source archive.

## Delivery phases

1. Native interaction shell and normalized domain boundary.
2. ZIP64 entry catalog and archive diagnostics.
3. Folder/message XML parsing and lazy body loading.
4. Attachment preview/export and SQLite/FTS5 search.
5. Contacts, calendars, conversation reconstruction, and optional AI.
