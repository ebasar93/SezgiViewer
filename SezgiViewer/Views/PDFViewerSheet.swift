import SwiftUI
import PDFKit

/// One page of one source PDF the viewer can show.
struct PDFViewerStop: Hashable {
    let url: URL
    let pageIndex: Int
    let title: String
}

/// Identifies which source pages to open in the viewer sheet. A single
/// highlight yields one stop; a combined highlight yields one stop per
/// distinct (document, page) pair among its members.
struct PDFViewerRequest: Identifiable {
    let id = UUID()
    let stops: [PDFViewerStop]
}

struct PDFViewerSheet: View {
    let request: PDFViewerRequest
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    private var current: PDFViewerStop {
        request.stops[min(index, request.stops.count - 1)]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(current.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Page \(current.pageIndex + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // Arrows only when the combined highlight spans several pages.
                if request.stops.count > 1 {
                    stopNavigator
                    Spacer()
                }
                Button {
                    NSWorkspace.shared.open(current.url)
                } label: {
                    Label("Open in Preview", systemImage: "arrow.up.forward.app")
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            PDFKitView(url: current.url, pageIndex: current.pageIndex)
        }
        .frame(minWidth: 640, minHeight: 560)
    }

    private var stopNavigator: some View {
        HStack(spacing: 8) {
            Button {
                index -= 1
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(index == 0)
            .keyboardShortcut(.leftArrow, modifiers: [])

            Text("\(index + 1) of \(request.stops.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                index += 1
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(index == request.stops.count - 1)
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .controlSize(.small)
        .help("Step through the pages this combined highlight was taken from")
    }
}

/// Wraps `PDFView`, managing security-scoped access for the file's lifetime
/// on screen and jumping to the requested page. Reloads when the viewer steps
/// to a stop in a different document or on a different page.
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
        context.coordinator.show(url: url, pageIndex: pageIndex, in: view)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        context.coordinator.show(url: url, pageIndex: pageIndex, in: nsView)
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        coordinator.releaseAccess()
    }

    final class Coordinator {
        private var accessedURL: URL?
        private var loadedURL: URL?
        private var shownPageIndex: Int?

        func show(url: URL, pageIndex: Int, in view: PDFView) {
            if loadedURL != url {
                releaseAccess()
                if url.startAccessingSecurityScopedResource() {
                    accessedURL = url
                }
                view.document = PDFDocument(url: url)
                loadedURL = url
                shownPageIndex = nil
            }
            guard shownPageIndex != pageIndex else { return }
            shownPageIndex = pageIndex
            if let document = view.document,
               let page = document.page(at: min(pageIndex, max(0, document.pageCount - 1))) {
                DispatchQueue.main.async {
                    view.go(to: page)
                }
            }
        }

        func releaseAccess() {
            accessedURL?.stopAccessingSecurityScopedResource()
            accessedURL = nil
        }
    }
}
