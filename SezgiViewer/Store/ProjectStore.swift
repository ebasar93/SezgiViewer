import Foundation
import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// Central state: the tracked project, persistence, scanning and export.
@MainActor
final class ProjectStore: ObservableObject {

    @Published private(set) var trackedFiles: [TrackedPDF] = []
    @Published private(set) var aggregatedHighlights: [Highlight] = []
    @Published private(set) var lastRefreshed: Date?
    @Published private(set) var isScanning = false
    @Published var statusMessage: String?

    private let persistenceURL: URL

    struct PersistedProject: Codable {
        var trackedFiles: [TrackedPDF]
        var lastRefreshed: Date?
    }

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("SezgiViewer", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.persistenceURL = dir.appendingPathComponent("project.json")
        load()
        rebuildAggregated()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: persistenceURL) else { return }
        guard let project = try? JSONDecoder().decode(PersistedProject.self, from: data) else { return }
        trackedFiles = project.trackedFiles
        lastRefreshed = project.lastRefreshed
    }

    private func save() {
        let project = PersistedProject(trackedFiles: trackedFiles, lastRefreshed: lastRefreshed)
        guard let data = try? JSONEncoder().encode(project) else { return }
        try? data.write(to: persistenceURL, options: .atomic)
    }

    // MARK: - Adding / removing files

    /// Adds files from the given URLs, creating security-scoped bookmarks.
    func addFiles(urls: [URL]) {
        var added = 0
        let existingPaths = Set(trackedFiles.map { $0.lastKnownPath })

        for url in urls where url.pathExtension.lowercased() == "pdf" {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            // Skip obvious duplicates by path.
            if existingPaths.contains(url.path) { continue }

            let bookmark: Data
            do {
                bookmark = try url.bookmarkData(options: [.withSecurityScope],
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
            } catch {
                // Fall back to a plain bookmark if security-scoped creation fails.
                guard let plain = try? url.bookmarkData() else { continue }
                bookmark = plain
            }

            let record = TrackedPDF(displayName: url.lastPathComponent,
                                    bookmark: bookmark,
                                    lastKnownPath: url.path)
            trackedFiles.append(record)
            added += 1
        }

        if added > 0 {
            save()
            statusMessage = "Added \(added) file\(added == 1 ? "" : "s")"
            Task { await refresh() }
        }
    }

    func removeFiles(ids: Set<UUID>) {
        trackedFiles.removeAll { ids.contains($0.id) }
        rebuildAggregated()
        save()
    }

    func removeFile(_ id: UUID) {
        removeFiles(ids: [id])
    }

    // MARK: - Scanning / refresh

    /// Re-scans every tracked file (parsing only changed/new ones) and rebuilds
    /// the aggregated highlight list.
    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        // Snapshot the inputs so scanning can run off the main actor.
        let inputs: [(UUID, String, Data, Date?)] = trackedFiles.map {
            ($0.id, $0.displayName, $0.bookmark, $0.lastModified)
        }

        var outcomes: [ScanOutcome] = []
        for input in inputs {
            let outcome = await Task.detached(priority: .userInitiated) {
                PDFHighlightExtractor.scan(recordID: input.0,
                                           displayName: input.1,
                                           bookmark: input.2,
                                           storedModified: input.3)
            }.value
            outcomes.append(outcome)
        }

        var emptyFileNames: [String] = []

        for outcome in outcomes {
            guard let idx = trackedFiles.firstIndex(where: { $0.id == outcome.recordID }) else { continue }
            trackedFiles[idx].status = outcome.status
            if let path = outcome.resolvedPath { trackedFiles[idx].lastKnownPath = path }
            if let modified = outcome.lastModified { trackedFiles[idx].lastModified = modified }
            if let fresh = outcome.freshHighlights {
                // Full replacement — prevents duplicate entries on re-scan.
                trackedFiles[idx].cachedHighlights = fresh
            }
            if outcome.becameEmpty {
                emptyFileNames.append(trackedFiles[idx].displayName)
            }
        }

        rebuildAggregated()
        lastRefreshed = Date()
        save()

        for name in emptyFileNames {
            NotificationManager.notifyNoHighlights(fileName: name)
        }

        let available = trackedFiles.filter { $0.status == .ok }.count
        statusMessage = "Refreshed · \(aggregatedHighlights.count) highlights from \(available) file\(available == 1 ? "" : "s")"
    }

    private func rebuildAggregated() {
        aggregatedHighlights = trackedFiles.flatMap { $0.exportableHighlights }
    }

    // MARK: - Export

    /// Suggested default filename, e.g. "Highlights Summary 2026-07-18.pdf".
    var defaultExportFilename: String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return "Highlights Summary \(df.string(from: Date())).pdf"
    }

    /// Generates the combined summary PDF at the chosen destination.
    func exportSummary(to url: URL) {
        do {
            try SummaryPDFGenerator.generate(highlights: aggregatedHighlights,
                                             generatedAt: Date(),
                                             to: url)
            statusMessage = "Exported summary to \(url.lastPathComponent)"
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Source access

    /// Resolves the on-disk URL for a tracked file, if still reachable.
    /// The caller is responsible for calling `startAccessingSecurityScopedResource`.
    func resolveURL(for id: UUID) -> URL? {
        guard let record = trackedFiles.first(where: { $0.id == id }) else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: record.bookmark,
                        options: [.withSecurityScope],
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale)
    }

    func trackedFile(for id: UUID) -> TrackedPDF? {
        trackedFiles.first { $0.id == id }
    }
}
