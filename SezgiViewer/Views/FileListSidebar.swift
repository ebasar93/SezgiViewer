import SwiftUI
import UniformTypeIdentifiers

struct FileListSidebar: View {
    @EnvironmentObject private var store: ProjectStore
    @Binding var showFileImporter: Bool

    @State private var search = ""
    @State private var isDropTargeted = false

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
                            FileRow(file: file)
                                .contextMenu {
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
                    Text("Tracked PDFs")
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

private struct FileRow: View {
    let file: TrackedPDF

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            statusBadge
        }
        .padding(.vertical, 2)
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
