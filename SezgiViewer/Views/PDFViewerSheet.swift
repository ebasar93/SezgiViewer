import SwiftUI
import PDFKit

/// Identifies which source PDF/page to open in the viewer sheet.
struct PDFViewerRequest: Identifiable {
    let id = UUID()
    let url: URL
    let pageIndex: Int
    let title: String
}

struct PDFViewerSheet: View {
    let request: PDFViewerRequest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(request.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Page \(request.pageIndex + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(request.url)
                } label: {
                    Label("Open in Preview", systemImage: "arrow.up.forward.app")
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            PDFKitView(url: request.url, pageIndex: request.pageIndex)
        }
        .frame(minWidth: 640, minHeight: 560)
    }
}

/// Wraps `PDFView`, managing security-scoped access for the file's lifetime
/// on screen and jumping to the requested page.
struct PDFKitView: NSViewRepresentable {
    let url: URL
    let pageIndex: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = NSColor.windowBackgroundColor

        let accessing = url.startAccessingSecurityScopedResource()
        context.coordinator.accessedURL = accessing ? url : nil

        if let document = PDFDocument(url: url) {
            view.document = document
            if let page = document.page(at: min(pageIndex, max(0, document.pageCount - 1))) {
                DispatchQueue.main.async {
                    view.go(to: page)
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {}

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        coordinator.accessedURL?.stopAccessingSecurityScopedResource()
        coordinator.accessedURL = nil
    }

    final class Coordinator {
        var accessedURL: URL?
    }
}
