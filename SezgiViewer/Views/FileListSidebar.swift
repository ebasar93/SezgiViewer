import SwiftUI
import UniformTypeIdentifiers

struct FileListSidebar: View {
    @EnvironmentObject private var store: ProjectStore
    @Binding var showFileImporter: Bool

    @State private var search = ""
    @State private var isDropTargeted = false
    @State private var dropTargetID: UUID?

    private var filtered: [TrackedPDF] {
        guard !search.isEmpty else { return store.trackedFiles }
        return store.trackedFiles.filter {
            $0.displayName.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    if store.trackedFiles.isEmpty {
                        emptyRow
                    } else if filtered.isEmpty {
                        Text("No matches")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        ForEach(filtered) { file in
                            FileRow(file: file, isDropTarget: dropTargetID == file.id) {
                                store.toggleSelection(file.id)
                            }
                            // Explicit drag-and-drop reordering (reliable across list
                            // styles). Only enabled when the list is unfiltered.
                            .draggable(file.id.uuidString) {
                                DragPreview(name: file.displayName)
                            }
                            .dropDestination(for: String.self) { items, _ in
                                dropTargetID = nil
                                guard search.isEmpty,
                                      let idString = items.first,
                                      let draggedID = UUID(uuidString: idString) else { return false }
                                store.moveFile(id: draggedID, beforeID: file.id)
                                return true
                            } isTargeted: { targeted in
                                dropTargetID = targeted ? file.id : (dropTargetID == file.id ? nil : dropTargetID)
                            }
                            .contextMenu {
                                Button(file.isSelected ? "Deselect" : "Select") {
                                    store.toggleSelection(file.id)
                                }
                                Divider()
                                Button("Remove from Project", role: .destructive) {
                                    store.removeFile(file.id)
                                }
                                Button("Reveal in Finder") {
                                    reveal(file)
                                }
                            }
                            .swipeActions {
                                Button("Remove", role: .destructive) {
                                    store.removeFile(file.id)
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Tracked PDFs")
                        Spacer()
                        if !store.trackedFiles.isEmpty {
                            Text("\(store.trackedFiles.filter { $0.isSelected }.count) selected")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .textCase(nil)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $search, placement: .sidebar, prompt: "Filter files")

            refreshFooter
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var emptyRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("No PDFs yet")
                .font(.headline)
            Text("Add PDFs or drag them here to start tracking highlights.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Add PDFs…") { showFileImporter = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 2)
        }
        .padding(.vertical, 8)
    }

    private var refreshFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Label("\(store.trackedFiles.count) file\(store.trackedFiles.count == 1 ? "" : "s")",
                      systemImage: "tray.full")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await store.refresh() }
                } label: {
                    if store.isScanning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .controlSize(.small)
                .disabled(store.isScanning || store.trackedFiles.isEmpty)
            }
            Text(lastRefreshedText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var lastRefreshedText: String {
        guard let date = store.lastRefreshed else { return "Last refreshed: never" }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return "Last refreshed: \(df.string(from: date))"
    }

    private func reveal(_ file: TrackedPDF) {
        if let url = store.resolveURL(for: file.id) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.pathExtension.lowercased() == "pdf" {
                    urls.append(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if !urls.isEmpty { store.addFiles(urls: urls) }
        }
        return true
    }
}

private struct DragPreview: View {
    let name: String
    var body: some View {
        Label(name, systemImage: "doc.richtext")
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct FileRow: View {
    let file: TrackedPDF
    var isDropTarget: Bool = false
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Insertion indicator shown above the row currently under the drag.
            Rectangle()
                .fill(isDropTarget ? Color.accentColor : Color.clear)
                .frame(height: 2)
                .padding(.bottom, 2)
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: file.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(file.isSelected ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(file.isSelected ? "Exclude from summary" : "Include in summary")

            Image(systemName: "doc.richtext")
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .layoutPriority(1)
            statusBadge
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(file.isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(file.isSelected ? Color.accentColor.opacity(0.55) : Color.clear,
                              lineWidth: 1)
        )
        .opacity(file.isSelected ? 1.0 : 0.5)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: file.isSelected)
    }

    private var iconColor: Color {
        switch file.status {
        case .missing, .unreadable: return .secondary
        default: return .accentColor
        }
    }

    private var subtitle: String {
        switch file.status {
        case .ok:
            let n = file.cachedHighlights.count
            return "\(n) highlight\(n == 1 ? "" : "s")"
        case .empty: return "No highlights"
        case .missing: return "File not found"
        case .unreadable: return "Can't read (locked/corrupt)"
        case .unscanned: return "Not scanned yet"
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch file.status {
        case .ok:
            Text("\(file.cachedHighlights.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
        case .missing, .unreadable:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .empty:
            Image(systemName: "circle.slash")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .unscanned:
            EmptyView()
        }
    }
}
