import SwiftUI

struct HighlightListView: View {
    @EnvironmentObject private var store: ProjectStore
    let onOpen: (HighlightEntry) -> Void

    @State private var selection = Set<HighlightEntry>()
    @State private var search = ""
    @State private var colorFilter: String? = nil
    @State private var showDeleted = false

    private var colorNames: [String] {
        var seen: [String] = []
        for entry in store.aggregatedEntries {
            for color in entry.colors {
                let name = color.approximateName
                if !seen.contains(name) { seen.append(name) }
            }
        }
        return seen.sorted()
    }

    private var filtered: [HighlightEntry] {
        store.aggregatedEntries.filter { entry in
            let matchesSearch = search.isEmpty
                || entry.combinedText.localizedCaseInsensitiveContains(search)
                || entry.sourceNames.contains { $0.localizedCaseInsensitiveContains(search) }
            let matchesColor = colorFilter == nil
                || entry.colors.contains { $0.approximateName == colorFilter }
            return matchesSearch && matchesColor
        }
    }

    var body: some View {
        Group {
            if store.aggregatedEntries.isEmpty && store.deletedHighlights.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Highlights")
        .navigationSubtitle(subtitle)
        .searchable(text: $search, placement: .toolbar, prompt: "Search highlights")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                colorFilterMenu
            }
        }
    }

    private var subtitle: String {
        let total = store.aggregatedEntries.count
        let shown = filtered.count
        if shown == total { return "\(total) entr\(total == 1 ? "y" : "ies")" }
        return "\(shown) of \(total)"
    }

    private var colorFilterMenu: some View {
        Menu {
            Button {
                colorFilter = nil
            } label: {
                Label("All Colors", systemImage: colorFilter == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(colorNames, id: \.self) { name in
                Button {
                    colorFilter = name
                } label: {
                    Label(name, systemImage: colorFilter == name ? "checkmark" : "")
                }
            }
            if !store.deletedHighlights.isEmpty {
                Divider()
                Toggle(isOn: $showDeleted) {
                    Text("Show Recently Deleted (\(store.deletedHighlights.count))")
                }
            }
        } label: {
            Label(colorFilter ?? "All Colors", systemImage: "line.3.horizontal.decrease.circle")
        }
        .disabled(colorNames.isEmpty && store.deletedHighlights.isEmpty)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(filtered) { entry in
                EntryRow(entry: entry, options: store.displayOptions)
                    .tag(entry)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onOpen(entry) }
            }
            if showDeleted && !store.deletedHighlights.isEmpty {
                deletedSection
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: HighlightEntry.self) { items in
            if items.count == 1, let entry = items.first {
                Button("Open in Source PDF") { onOpen(entry) }
                if entry.isCombined {
                    Button("Uncombine") { store.uncombineEntry(entry) }
                }
                Divider()
                Button("Delete from App", role: .destructive) { delete([entry]) }
            } else if items.count >= 2 {
                Button("Combine \(items.count) Entries") {
                    store.combineEntries(items)
                    selection.removeAll()
                }
                Divider()
                Button("Delete from App", role: .destructive) { delete(Array(items)) }
            }
        } primaryAction: { items in
            if let entry = items.first { onOpen(entry) }
        }
        .onDeleteCommand {
            if !selection.isEmpty { delete(Array(selection)) }
        }
        .overlay(alignment: .bottom) {
            openHintBar
        }
    }

    private var deletedSection: some View {
        Section {
            ForEach(store.deletedHighlights) { highlight in
                EntryRow(entry: HighlightEntry(id: highlight.fingerprint,
                                               groupID: nil,
                                               members: [highlight]),
                         options: store.displayOptions)
                    .opacity(0.45)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Restore") { store.restoreHighlight(highlight) }
                    }
            }
        } header: {
            HStack {
                Text("Recently Deleted")
                Spacer()
                Button("Restore All") { store.restoreAllDeleted() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        } footer: {
            Text("Deleted highlights are hidden from the list and export only — the source PDFs are never modified.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func delete(_ entries: [HighlightEntry]) {
        for entry in entries {
            selection.remove(entry)
            store.deleteEntry(entry)
        }
    }

    private var openHintBar: some View {
        HStack {
            Image(systemName: "hand.tap")
            Text("Double-click an entry to open it on its page in the source PDF")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "highlighter")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No highlights to show")
                .font(.title3.weight(.medium))
            Text(store.trackedFiles.isEmpty
                 ? "Add PDF files, then Refresh to extract their highlights."
                 : "Press Refresh to scan your tracked PDFs for highlights.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !store.trackedFiles.isEmpty {
                Button("Refresh") { Task { await store.refresh() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isScanning)
            }
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EntryRow: View {
    let entry: HighlightEntry
    let options: DisplayOptions

    private var showsDate: Bool { options.showDate && entry.primary.date != nil }
    private var hasMeta: Bool {
        options.showSource || options.showPage || showsDate || entry.isCombined
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            swatches
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.combinedText)
                    .font(.system(size: 13))
                    .lineLimit(entry.isCombined ? 8 : 4)
                    .fixedSize(horizontal: false, vertical: true)

                if hasMeta {
                    metaLine
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// One swatch per distinct member color, stacked vertically (max 3).
    private var swatches: some View {
        VStack(spacing: 2) {
            ForEach(Array(entry.colors.prefix(3).enumerated()), id: \.offset) { _, color in
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.swiftUIColor)
                    .frame(width: 12, height: 12)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.1)))
            }
        }
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            if entry.isCombined {
                Label("\(entry.members.count)", systemImage: "link")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    .help("Combined from \(entry.members.count) highlights")
            }
            if options.showSource {
                Text(entry.sourceNames.joined(separator: ", "))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if options.showPage {
                if options.showSource { Text("·") }
                Text("p. \(entry.pageLabels.joined(separator: ", "))")
            }
            if showsDate, let date = entry.primary.date {
                if options.showSource || options.showPage { Text("·") }
                Text(date, style: .date)
            }
        }
    }
}
