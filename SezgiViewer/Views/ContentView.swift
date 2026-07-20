import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var manager: ProjectManager

    @State private var showFileImporter = false
    @State private var showExporter = false
    @State private var viewerRequest: PDFViewerRequest?

    var body: some View {
        NavigationSplitView {
            FileListSidebar(showFileImporter: $showFileImporter)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            HighlightListView(onOpen: openSource)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    manager.closeProject()
                } label: {
                    Label(manager.activeProject?.name ?? "Projects",
                          systemImage: "chevron.backward")
                        .labelStyle(.titleAndIcon)
                }
                .help("Back to projects")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showFileImporter = true
                } label: {
                    Label("Add PDFs", systemImage: "plus")
                }
                .help("Add PDF files to the project")

                Menu {
                    ForEach(HighlightSort.allCases, id: \.self) { option in
                        Button {
                            store.sortOption = option
                        } label: {
                            Label(option.label,
                                  systemImage: store.sortOption == option ? "checkmark" : option.systemImage)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort highlights by date or length")
                .disabled(store.aggregatedEntries.isEmpty)

                Menu {
                    Toggle("Show Page", isOn: $store.displayOptions.showPage)
                    Toggle("Show Source", isOn: $store.displayOptions.showSource)
                    Toggle("Show Date", isOn: $store.displayOptions.showDate)
                } label: {
                    Label("View Options", systemImage: "eye")
                }
                .help("Choose which details appear in the list and the exported PDF")

                Button {
                    Task { await store.refresh() }
                } label: {
                    if store.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(store.isScanning || store.trackedFiles.isEmpty)
                .help("Re-scan changed files and rebuild the summary")

                Button {
                    showExporter = true
                } label: {
                    Label("Export Summary", systemImage: "square.and.arrow.up")
                }
                .disabled(store.aggregatedEntries.isEmpty)
                .help("Export the combined highlights summary PDF")
            }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.pdf],
                      allowsMultipleSelection: true) { result in
            if case let .success(urls) = result {
                store.addFiles(urls: urls)
            }
        }
        .fileExporter(isPresented: $showExporter,
                      document: SummaryDocument(store: store),
                      contentType: .pdf,
                      defaultFilename: store.defaultExportFilename) { result in
            if case let .success(url) = result {
                store.statusMessage = "Exported to \(url.lastPathComponent)"
            }
        }
        .sheet(item: $viewerRequest) { request in
            PDFViewerSheet(request: request)
        }
        .onReceive(NotificationCenter.default.publisher(for: .sezgiAddFiles)) { _ in
            showFileImporter = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .sezgiRefresh)) { _ in
            Task { await store.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sezgiExport)) { _ in
            if !store.aggregatedEntries.isEmpty { showExporter = true }
        }
    }

    /// Opens the viewer with one stop per distinct (document, page) pair among
    /// the entry's members; a single highlight yields a single stop (no arrows).
    private func openSource(_ entry: HighlightEntry) {
        var stops: [PDFViewerStop] = []
        var seen = Set<String>()
        for member in entry.members {
            let key = "\(member.sourceID.uuidString)|\(member.pageIndex)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            guard let url = store.resolveURL(for: member.sourceID) else { continue }
            stops.append(PDFViewerStop(url: url,
                                       pageIndex: member.pageIndex,
                                       title: member.sourceName))
        }
        guard !stops.isEmpty else {
            store.statusMessage = "Source file is unavailable"
            return
        }
        viewerRequest = PDFViewerRequest(stops: stops)
    }
}

/// A lightweight `FileDocument` wrapper that renders the summary on demand for
/// the SwiftUI file exporter.
struct SummaryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    let data: Data

    @MainActor
    init(store: ProjectStore) {
        // Render into a temporary file, then read it back as data.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try? SummaryPDFGenerator.generate(entries: store.aggregatedEntries,
                                          generatedAt: Date(),
                                          options: store.displayOptions,
                                          to: tmp)
        self.data = (try? Data(contentsOf: tmp)) ?? Data()
        try? FileManager.default.removeItem(at: tmp)
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
