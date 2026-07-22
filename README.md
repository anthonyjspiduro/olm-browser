# OLM Browser

A native, read-only macOS utility for browsing Microsoft Outlook `.olm` archives without importing them into Outlook.

This repository now contains the native SwiftUI browsing shell and the first production archive-reader milestone. It catalogs ZIP64 OLM files in place, discovers accounts and folders, and parses a bounded set of real message XML records without modifying or expanding the source archive.

## Product principles

- Never modify the source OLM.
- Open large archives in place instead of expanding them wholesale.
- Make browsing available before background indexing finishes.
- Keep cached indexes disposable and trace every result to its source record.
- Extract attachments only on explicit preview or export.
- Keep AI optional, privacy-aware, and grounded in selected messages.

## Run the design build

```sh
swift run
```

Run the parser smoke check without XCTest or full Xcode:

```sh
swiftc Sources/OLMBrowser/Models/ArchiveModels.swift \
  Sources/OLMBrowser/Services/OLMMessageParser.swift \
  Checks/ParserSmokeCheck.swift \
  -o /tmp/olm-parser-check && /tmp/olm-parser-check
```

The package targets macOS 14 or later. Choose **Open OLM** to exercise the archive-opening flow. The current reader loads up to 40 recent archive entries per folder while paging and persistent indexing are developed.

Copied archives whose Finder name ends in `.olm copy` are also accepted during development. The production reader will identify supported archives by their content signature instead of trusting the filename alone.

## Project layout

- `Models/` contains normalized mailbox and message types.
- `Services/` defines the read-only archive boundary and the temporary preview implementation.
- `Views/` contains the three-pane macOS browsing interface.
- `Design/ARCHITECTURE.md` describes the parser, index, privacy, and delivery plan.

## Next implementation milestone

1. Move cataloging and parsing onto cancellable background tasks.
2. Add per-folder paging instead of the temporary 40-message bound.
3. Resolve attachment payloads and add safe temporary previews.
4. Persist metadata and full-text content in a disposable SQLite/FTS5 index.
5. Add resumable indexing progress and archive diagnostics.
