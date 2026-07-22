# OLM Browser

A native, read-only macOS utility for browsing Microsoft Outlook `.olm` archives without importing them into Outlook.

The app catalogs ZIP64 OLM files in place, displays nested Outlook folders, pages through messages on demand, and builds a resumable SQLite/FTS5 index for archive-wide search without modifying or expanding the source archive.

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

Build a double-clickable, ad-hoc-signed macOS application bundle:

```sh
zsh Scripts/build-app.sh
```

The bundle is written to `dist/OLM Browser.app` and registers `.olm` files as documents it can view.

Run the parser smoke check without XCTest or full Xcode:

```sh
swiftc Sources/OLMBrowser/Models/ArchiveModels.swift \
  Sources/OLMBrowser/Services/OLMMessageParser.swift \
  Checks/ParserSmokeCheck.swift \
  -o /tmp/olm-parser-check && /tmp/olm-parser-check
```

The package targets macOS 14 or later. Choose **Open OLM** to exercise the archive-opening flow. Messages load in 100-item pages as the user scrolls. Full-text indexing runs at utility priority and resumes from its last committed batch the next time the same archive is opened.

Copied archives whose Finder name ends in `.olm copy` are also accepted during development. The production reader will identify supported archives by their content signature instead of trusting the filename alone.

## Project layout

- `Models/` contains normalized mailbox and message types.
- `Services/` defines the read-only archive boundary and the temporary preview implementation.
- `Views/` contains the three-pane macOS browsing interface.
- `Design/ARCHITECTURE.md` describes the parser, index, privacy, and delivery plan.

## Current browsing capabilities

- Finder-launchable `.app` bundle with `.olm` document registration
- Expandable Outlook folder hierarchy
- Incremental 100-message paging
- Persistent, resumable SQLite/FTS5 search across message text and attachment names
- Visible search-index progress
- Read-only ZIP64 random access

Attachment payload preview/export and production signing/notarization remain future work.
