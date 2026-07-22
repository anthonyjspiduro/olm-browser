# OLM Browser

OLM Browser is a native, read-only macOS utility for browsing Microsoft Outlook `.olm` archives without importing them into Outlook.

It catalogs ZIP64 OLM files in place, displays nested Outlook folders, pages through messages on demand, renders plain-text or secured HTML email, and builds a resumable SQLite/FTS5 index for archive-wide search. The source archive is never rewritten or expanded wholesale.

## Requirements

- macOS 14 or later
- Apple Silicon for the current packaged build
- Swift Command Line Tools to build from source

The reader has been validated against a 26 GB OLM containing 83,172 messages across 64 folders.

## Current features

- Native three-column SwiftUI interface
- Finder-launchable, ad-hoc-signed `OLM Browser.app`
- `.olm` Finder document registration and Open dialog
- Read-only ZIP64 central-directory parsing and random-access entry reads
- Stored and raw-DEFLATE ZIP entry support through a minimal zlib bridge
- Rejection of encrypted entries and bounded entry decompression
- Automatic Outlook account and folder discovery
- Expandable nested folder hierarchy
- Folder message counts
- Incremental 100-message paging while scrolling
- Sender, recipient, subject, sent date, preview, body, read state, and flag display
- Attachment filename, content type, and size display
- Plain-text message rendering with selectable text
- Secured HTML email rendering with:
  - JavaScript disabled
  - Ephemeral WebKit storage
  - Remote images and other network resources blocked
  - Frames, objects, forms, media, and network connections blocked
  - Navigation and popup creation blocked
  - Referrer suppression
  - Responsive images and dark-mode support
  - An explicit HTML/Plain Text toggle
- Persistent SQLite/FTS5 search across subjects, participants, previews, bodies, and attachment names
- Search available while background indexing continues
- Resumable 250-entry index transactions
- Visible search-index progress
- Disposable, archive-fingerprinted indexes in the macOS user cache
- Background archive opening, paging, search, and indexing
- Standalone parser, paging, and FTS5 smoke checks

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

## Search behavior

Full-text indexing begins after the archive folder catalog opens. Messages remain browsable while indexing runs. The index commits every 250 entries and records its next position in the same transaction, allowing interrupted indexing to resume safely.

Search results may be incomplete until the progress indicator finishes. Derived search databases can be deleted without affecting the source OLM.

## Privacy and safety

- The OLM is opened for reading only.
- Messages and attachments are not uploaded anywhere.
- HTML email runs with JavaScript disabled.
- Remote content and tracking pixels are blocked by Content Security Policy.
- The HTML viewer uses a nonpersistent WebKit data store.
- Search indexes remain local in the user's cache directory.
- AI and cloud services are not currently connected.

## Known limitations

- Attachment metadata is visible, but attachment payload preview and export are not implemented.
- Inline `cid:` images are not resolved yet.
- HTML links are displayed but navigation is intentionally blocked.
- Search supports text terms but not structured filters such as `from:` or `after:` yet.
- Search results are currently limited to 500 messages per query.
- CC and BCC fields are not displayed yet.
- Folder unread totals are not fully calculated.
- The packaged build is Apple Silicon only and ad-hoc signed, not notarized.
- Calendar and contact records are not browsable yet.
- The managed Command Line Tools installation does not include XCTest, so checks are standalone executables.

## Planned features

1. Resolve attachment payloads to their archive entries.
2. Add Quick Look, Save As, drag-to-Finder, and batch attachment export.
3. Resolve inline `cid:` images without permitting remote network access.
4. Add structured search filters, date ranges, folder scoping, and result paging.
5. Add opening/indexing cancellation, cache controls, and detailed diagnostics.
6. Add message export as `.eml`, PDF, text, JSON, and CSV.
7. Reconstruct conversations and expose richer message headers.
8. Add CRC verification and more granular corrupt-entry recovery.
9. Add recent archives, drag-and-drop opening, and persistent security-scoped access.
10. Add contacts and calendar browsing.
11. Add optional local or explicitly configured grounded AI features.
12. Produce a universal binary, Developer ID signature, notarization, and distributable DMG.
13. Expand accessibility, keyboard-navigation, locale, and cross-version OLM testing.

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
- Keep future AI optional, privacy-aware, and grounded in source messages.
