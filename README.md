# SezgiViewer

A native macOS (SwiftUI) app for Apple Silicon that extracts **highlight
annotations** from PDF files and compiles them into a single, cleanly styled
summary PDF. Styled to resemble Apple's Preview / native design language.

## Features

- **Tracked project** — add PDFs via the file picker or drag-and-drop; the set
  is saved between launches using **security-scoped bookmarks** (works under the
  App Sandbox, so tracked files stay accessible after relaunch).
- **Filterable file list** — search tracked filenames; remove files via
  right-click / swipe.
- **Highlights only** — parses highlight annotations with PDFKit (compatible
  with Preview, Skim, Adobe Acrobat, etc.). Underlines, strikethroughs and
  sticky notes are ignored.
- Per highlight, extracts: **text, color, source filename, page, and date**
  (annotation modification date, falling back to PDF metadata; handled
  gracefully when absent).
- **In-app viewing** — double-click any highlight to open its **page in the
  source PDF**, or open it in Preview.
- **Combined summary PDF** — one continuous list across all files, each entry
  showing the source name, a **colored swatch** matching the highlight, the
  text, and the date. SF font, generous margins, subtle dividers, automatic
  pagination for 100+ page inputs.
- **Save anywhere** — export via a save panel with a sensible default name,
  `Highlights Summary <date>.pdf`.

## Refresh & persistence

- Each file's path and last-modified timestamp are stored after every scan.
- **Refresh** compares each file's current modification date to the stored one,
  re-parses only new/changed files, reuses the cache for unchanged ones, then
  rebuilds the summary fresh (no in-place PDF editing).
- A **Last refreshed** timestamp is shown in the sidebar.
- Re-scanning fully replaces a file's cached highlights, so edits/removals never
  produce duplicate entries.

## Edge cases

- Missing / moved / deleted file → silently excluded from the output (flagged in
  the list, no crash).
- Zero highlights → a local notification "No highlights found in `<file>`", and
  the file is excluded from the output.
- Corrupted or password-protected PDFs → skipped gracefully.

## Requirements

- Apple Silicon Mac (arm64), macOS 14.0+
- Xcode 16+ (built and tested with Xcode 26 / Swift 6.3)

## Build & run

```sh
./build.sh                 # release build → build/Release/SezgiViewer.app
open build/Release/SezgiViewer.app
```

Or open `SezgiViewer.xcodeproj` in Xcode and press ⌘R.

The app is ad-hoc signed ("Sign to Run Locally") with the App Sandbox and
security-scoped bookmark entitlements — no notarization or developer account
required for local use.

## Keyboard shortcuts

| Action           | Shortcut |
|------------------|----------|
| Add PDFs…        | ⌘O       |
| Refresh          | ⌘R       |
| Export Summary…  | ⌘E       |

## Project layout

```
SezgiViewer/
  SezgiViewerApp.swift         App entry, menu commands
  Models/Models.swift          Highlight, TrackedPDF, RGBAColor, FileStatus
  Store/ProjectStore.swift     Persistence, bookmarks, refresh, export
  Services/
    PDFHighlightExtractor.swift  PDFKit highlight parsing (background-safe)
    SummaryPDFGenerator.swift    Paginated, native-styled PDF renderer
    NotificationManager.swift    Local "no highlights" notifications
  Views/
    ContentView.swift          Split layout, toolbar, importer/exporter
    FileListSidebar.swift       Tracked files, search, drag-and-drop, refresh
    HighlightListView.swift     Aggregated highlights, search + color filter
    PDFViewerSheet.swift        Jump-to-page source viewer
  SezgiViewer.entitlements     Sandbox + security-scoped bookmarks
```
# SezgiViewer
# SezgiViewer
