import SwiftUI

struct HighlightListView: View {
    @EnvironmentObject private var store: ProjectStore
    @Binding var selectedHighlight: Highlight?
    let onOpen: (Highlight) -> Void

    @State private var search = ""
    @State private var colorFilter: String? = nil

    private var colorNames: [String] {
        var seen: [String] = []
        for h in store.aggregatedHighlights {
            let name = h.color.approximateName
            if !seen.contains(name) { seen.append(name) }
        }
        return seen.sorted()
    }

    private var filtered: [Highlight] {
        store.aggregatedHighlights.filter { h in
            let matchesSearch = search.isEmpty
                || h.text.localizedCaseInsensitiveContains(search)
                || h.sourceName.localizedCaseInsensitiveContains(search)
            let matchesColor = colorFilter == nil || h.color.approximateName == colorFilter
            return matchesSearch && matchesColor
        }
    }

    var body: some View {
        Group {
            if store.aggregatedHighlights.isEmpty {
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
        let total = store.aggregatedHighlights.count
        let shown = filtered.count
        if shown == total { return "\(total) highlight\(total == 1 ? "" : "s")" }
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
        } label: {
            Label(colorFilter ?? "All Colors", systemImage: "line.3.horizontal.decrease.circle")
        }
        .disabled(colorNames.isEmpty)
    }

    private var list: some View {
        List(selection: $selectedHighlight) {
            ForEach(filtered) { highlight in
                HighlightRow(highlight: highlight)
                    .tag(highlight)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onOpen(highlight) }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: Highlight.self) { _ in
        } primaryAction: { items in
            if let h = items.first { onOpen(h) }
        }
        .overlay(alignment: .bottom) {
            openHintBar
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

private struct HighlightRow: View {
    let highlight: Highlight

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(highlight.color.swiftUIColor)
                .frame(width: 12, height: 12)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.1)))
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(highlight.text)
                    .font(.system(size: 13))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Text(highlight.sourceName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("·")
                    Text("p. \(highlight.pageLabel ?? "\(highlight.pageIndex + 1)")")
                    if let date = highlight.date {
                        Text("·")
                        Text(date, style: .date)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
