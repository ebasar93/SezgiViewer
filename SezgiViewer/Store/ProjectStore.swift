import Foundation
import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// Central state: the tracked project, persistence, scanning and export.
@MainActor
final class ProjectStore: ObservableObject {

    @Published private(set) var trackedFiles: [TrackedPDF] = []
    /// The visible list: single highlights and combined groups, sorted.
    @Published private(set) var aggregatedEntries: [HighlightEntry] = []
    /// Highlights hidden app-side (the source PDFs are never modified).
    @Published private(set) var deletedHighlights: [Highlight] = []
    @Published private(set) var lastRefreshed: Date?
    @Published private(set) var isScanning = false
    @Published var statusMessage: String?
    @Published var sortOption: HighlightSort = .sourceOrder {
        didSet {
            guard sortOption != oldValue else { return }
            rebuildAggregated()
            save()
        }
    }
    @Published var displayOptions = DisplayOptions() {
        didSet {
            guard displayOptions != oldValue else { return }
            save()
        }
    }

    /// Fingerprints of highlights the user deleted from the app.
    private var deletedFingerprints: Set<String> = []
    /// User-created combinations, persisted by member fingerprint.
    private var groups: [HighlightGroup] = []

    private let persistenceURL: URL

    struct PersistedProject: Codable {
        var trackedFiles: [TrackedPDF]
        var lastRefreshed: Date?
        var sortOption: HighlightSort?
        var deletedFingerprints: Set<String>?
        var displayOptions: DisplayOptions?
        var groups: [HighlightGroup]?

        init(trackedFiles: [TrackedPDF],
             lastRefreshed: Date?,
             sortOption: HighlightSort?,
             deletedFingerprints: Set<String>?,
             displayOptions: DisplayOptions?,
             groups: [HighlightGroup]?) {
            self.trackedFiles = trackedFiles
            self.lastRefreshed = lastRefreshed
            self.sortOption = sortOption
            self.deletedFingerprints = deletedFingerprints
            self.displayOptions = displayOptions
            self.groups = groups
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            trackedFiles = try c.decodeIfPresent([TrackedPDF].self, forKey: .trackedFiles) ?? []
            lastRefreshed = try c.decodeIfPresent(Date.self, forKey: .lastRefreshed)
            sortOption = try c.decodeIfPresent(HighlightSort.self, forKey: .sortOption)
            deletedFingerprints = try c.decodeIfPresent(Set<String>.self, forKey: .deletedFingerprints)
            displayOptions = try c.decodeIfPresent(DisplayOptions.self, forKey: .displayOptions)
            groups = try c.decodeIfPresent([HighlightGroup].self, forKey: .groups)
        }
    }

    /// `persistenceURL` is the project's own JSON file, provided by `ProjectManager`.
    init(persistenceURL: URL) {
        self.persistenceURL = persistenceURL
        load()
        rebuildAggregated()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: persistenceURL) else { return }
        guard let project = try? JSONDecoder().decode(PersistedProject.self, from: data) else { return }
        trackedFiles = project.trackedFiles
        lastRefreshed = project.lastRefreshed
        if let sort = project.sortOption { sortOption = sort }
        deletedFingerprints = project.deletedFingerprints ?? []
        if let options = project.displayOptions { displayOptions = options }
        groups = project.groups ?? []
    }

    private func save() {
        let project = PersistedProject(trackedFiles: trackedFiles,
                                       lastRefreshed: lastRefreshed,
                                       sortOption: sortOption,
                                       deletedFingerprints: deletedFingerprints,
                                       displayOptions: displayOptions,
                                       groups: groups)
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

    /// Toggles whether a file's highlights are included in the output.
    func toggleSelection(_ id: UUID) {
        guard let idx = trackedFiles.firstIndex(where: { $0.id == id }) else { return }
        trackedFiles[idx].isSelected.toggle()
        rebuildAggregated()
        save()
    }

    func setSelection(_ isSelected: Bool, for id: UUID) {
        guard let idx = trackedFiles.firstIndex(where: { $0.id == id }) else { return }
        guard trackedFiles[idx].isSelected != isSelected else { return }
        trackedFiles[idx].isSelected = isSelected
        rebuildAggregated()
        save()
    }

    /// Reorders tracked files (drag-to-sort in the sidebar).
    func moveFiles(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        trackedFiles.move(fromOffsets: offsets, toOffset: destination)
        rebuildAggregated()
        save()
    }

    /// Moves the file with `id` so it sits immediately before `targetID`.
    /// Used by the explicit drag-and-drop reordering in the sidebar.
    func moveFile(id: UUID, beforeID targetID: UUID) {
        guard id != targetID,
              let from = trackedFiles.firstIndex(where: { $0.id == id }) else { return }
        let item = trackedFiles.remove(at: from)
        if let target = trackedFiles.firstIndex(where: { $0.id == targetID }) {
            trackedFiles.insert(item, at: target)
        } else {
            trackedFiles.append(item)
        }
        rebuildAggregated()
        save()
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

        // Drop deletion records whose highlight no longer exists in any tracked
        // file (edited or removed in the source PDF) so the set can't grow stale.
        let validFingerprints = Set(trackedFiles.flatMap { $0.cachedHighlights }.map(\.fingerprint))
        deletedFingerprints.formIntersection(validFingerprints)

        // Same for groups: release members that vanished; a group needs at
        // least two surviving members to stay meaningful.
        groups = groups.compactMap { group in
            var group = group
            group.memberFingerprints.removeAll { !validFingerprints.contains($0) }
            return group.memberFingerprints.count >= 2 ? group : nil
        }

        rebuildAggregated()
        lastRefreshed = Date()
        save()

        for name in emptyFileNames {
            NotificationManager.notifyNoHighlights(fileName: name)
        }

        let available = trackedFiles.filter { $0.status == .ok }.count
        let highlightCount = aggregatedEntries.reduce(0) { $0 + $1.members.count }
        statusMessage = "Refreshed · \(highlightCount) highlights from \(available) file\(available == 1 ? "" : "s")"
    }

    private func rebuildAggregated() {
        let combined = trackedFiles.flatMap { $0.exportableHighlights }
        let visible = combined.filter { !deletedFingerprints.contains($0.fingerprint) }
        deletedHighlights = sortOption.apply(to: combined.filter { deletedFingerprints.contains($0.fingerprint) })

        var byFingerprint: [String: Highlight] = [:]
        for h in visible where byFingerprint[h.fingerprint] == nil {
            byFingerprint[h.fingerprint] = h
        }

        // Resolve each group to the members currently visible.
        var groupEntries: [UUID: HighlightEntry] = [:]
        var consumed: [String: UUID] = [:]
        for group in groups {
            let members = group.memberFingerprints.compactMap { byFingerprint[$0] }
            guard !members.isEmpty else { continue }
            groupEntries[group.id] = HighlightEntry(id: group.id.uuidString,
                                                    groupID: group.id,
                                                    members: members)
            for member in members { consumed[member.fingerprint] = group.id }
        }

        // Walk the source-ordered list: a group entry sits where its first
        // member appears; other members are folded in.
        var entries: [HighlightEntry] = []
        var emittedGroups: Set<UUID> = []
        var singleCounts: [String: Int] = [:]
        for h in visible {
            if let groupID = consumed[h.fingerprint] {
                guard !emittedGroups.contains(groupID) else { continue }
                emittedGroups.insert(groupID)
                if let entry = groupEntries[groupID] { entries.append(entry) }
            } else {
                // Identical duplicate highlights share a fingerprint; suffix
                // repeats so list ids stay unique.
                let n = singleCounts[h.fingerprint, default: 0]
                singleCounts[h.fingerprint] = n + 1
                let id = n == 0 ? h.fingerprint : "\(h.fingerprint)#\(n)"
                entries.append(HighlightEntry(id: id, groupID: nil, members: [h]))
            }
        }
        aggregatedEntries = sortEntries(entries)
    }

    /// Entry-level counterpart of `HighlightSort.apply`. Combined entries sort
    /// by their first member's date and by total combined text length.
    private func sortEntries(_ entries: [HighlightEntry]) -> [HighlightEntry] {
        switch sortOption {
        case .sourceOrder:
            return entries
        case .dateDescending:
            return entries.sorted { lhs, rhs in
                switch (lhs.primary.date, rhs.primary.date) {
                case let (l?, r?): return l > r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return false
                }
            }
        case .dateAscending:
            return entries.sorted { lhs, rhs in
                switch (lhs.primary.date, rhs.primary.date) {
                case let (l?, r?): return l < r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return false
                }
            }
        case .lengthDescending:
            return entries.sorted { $0.combinedText.count > $1.combinedText.count }
        case .lengthAscending:
            return entries.sorted { $0.combinedText.count < $1.combinedText.count }
        }
    }

    // MARK: - Combining

    /// Merges the selected entries (singles and/or existing groups) into one
    /// combined entry, preserving current on-screen order.
    func combineEntries(_ selected: Set<HighlightEntry>) {
        let ordered = aggregatedEntries.filter { selected.contains($0) }
        let members = ordered.flatMap(\.members)
        guard members.count >= 2 else { return }
        let involvedGroups = Set(ordered.compactMap(\.groupID))
        groups.removeAll { involvedGroups.contains($0.id) }
        groups.append(HighlightGroup(memberFingerprints: members.map(\.fingerprint)))
        rebuildAggregated()
        save()
        statusMessage = "Combined \(members.count) highlights"
    }

    /// Splits a combined entry back into its individual highlights.
    func uncombineEntry(_ entry: HighlightEntry) {
        guard let groupID = entry.groupID else { return }
        groups.removeAll { $0.id == groupID }
        rebuildAggregated()
        save()
    }

    // MARK: - App-side deletion

    /// Hides an entry (all its members) from the list and export.
    /// The source PDFs are untouched.
    func deleteEntry(_ entry: HighlightEntry) {
        for member in entry.members {
            deletedFingerprints.insert(member.fingerprint)
        }
        rebuildAggregated()
        save()
    }

    func restoreHighlight(_ highlight: Highlight) {
        deletedFingerprints.remove(highlight.fingerprint)
        rebuildAggregated()
        save()
    }

    func restoreAllDeleted() {
        guard !deletedFingerprints.isEmpty else { return }
        deletedFingerprints.removeAll()
        rebuildAggregated()
        save()
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
            try SummaryPDFGenerator.generate(entries: aggregatedEntries,
                                             generatedAt: Date(),
                                             options: displayOptions,
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
