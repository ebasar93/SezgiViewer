import Foundation
import PDFKit
import AppKit

/// The outcome of scanning a single tracked file. Fully `Sendable` so it can
/// cross the boundary out of a background task.
struct ScanOutcome: Sendable {
    let recordID: UUID
    let status: FileStatus
    let lastModified: Date?
    /// `nil` means "unchanged — keep the cached highlights". A non-nil value
    /// (possibly empty) means the file was re-parsed and this is the fresh set.
    let freshHighlights: [Highlight]?
    let resolvedPath: String?
    /// True when the file was parsed this pass and yielded zero highlights.
    let becameEmpty: Bool
}

enum PDFHighlightExtractor {

    /// Scans a single tracked file off the main actor. Resolves the security-scoped
    /// bookmark, checks the modification date, and re-parses only when changed.
    static func scan(recordID: UUID,
                     displayName: String,
                     bookmark: Data,
                     storedModified: Date?) -> ScanOutcome {

        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: [.withSecurityScope],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else {
            return ScanOutcome(recordID: recordID, status: .missing,
                               lastModified: storedModified, freshHighlights: nil,
                               resolvedPath: nil, becameEmpty: false)
        }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return ScanOutcome(recordID: recordID, status: .missing,
                               lastModified: storedModified, freshHighlights: nil,
                               resolvedPath: url.path, becameEmpty: false)
        }

        let currentModified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate

        // Unchanged since last scan → keep the cache, avoid re-parsing.
        if let storedModified, let currentModified,
           abs(storedModified.timeIntervalSince(currentModified)) < 1.0 {
            return ScanOutcome(recordID: recordID, status: .ok,
                               lastModified: currentModified, freshHighlights: nil,
                               resolvedPath: url.path, becameEmpty: false)
        }

        // Corrupted or password-protected → skip gracefully.
        guard let document = PDFDocument(url: url) else {
            return ScanOutcome(recordID: recordID, status: .unreadable,
                               lastModified: currentModified, freshHighlights: nil,
                               resolvedPath: url.path, becameEmpty: false)
        }
        if document.isLocked {
            return ScanOutcome(recordID: recordID, status: .unreadable,
                               lastModified: currentModified, freshHighlights: nil,
                               resolvedPath: url.path, becameEmpty: false)
        }

        let highlights = extractHighlights(from: document,
                                           sourceID: recordID,
                                           sourceName: displayName)

        let status: FileStatus = highlights.isEmpty ? .empty : .ok
        return ScanOutcome(recordID: recordID, status: status,
                           lastModified: currentModified,
                           freshHighlights: highlights,
                           resolvedPath: url.path,
                           becameEmpty: highlights.isEmpty)
    }

    /// Parses every page for highlight annotations only.
    static func extractHighlights(from document: PDFDocument,
                                  sourceID: UUID,
                                  sourceName: String) -> [Highlight] {
        var results: [Highlight] = []
        let docModified = document.documentAttributes?[PDFDocumentAttribute.modificationDateAttribute] as? Date
        let docCreated = document.documentAttributes?[PDFDocumentAttribute.creationDateAttribute] as? Date
        let fallbackDate = docModified ?? docCreated

        let pageCount = document.pageCount
        for pageIndex in 0..<pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let pageLabel = page.label
            for annotation in page.annotations {
                // Highlights only — skip underline, strikeOut, squiggly, text notes, etc.
                guard isHighlight(annotation) else { continue }

                let text = extractText(for: annotation, on: page)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                let color = RGBAColor(nsColor: annotation.color)
                    ?? RGBAColor(red: 1, green: 0.9, blue: 0.3, alpha: 1)

                let date = annotation.modificationDate ?? fallbackDate

                results.append(Highlight(sourceID: sourceID,
                                         sourceName: sourceName,
                                         text: trimmed,
                                         color: color,
                                         pageIndex: pageIndex,
                                         pageLabel: pageLabel,
                                         date: date))
            }
        }
        return results
    }

    private static func isHighlight(_ annotation: PDFAnnotation) -> Bool {
        // PDFKit reports the subtype via `type` as a string, e.g. "Highlight".
        if let type = annotation.type {
            return type.caseInsensitiveCompare("Highlight") == .orderedSame
        }
        return false
    }

    /// Recovers the highlighted text using the annotation's quadrilateral points,
    /// falling back to the bounding box, then to the annotation contents.
    private static func extractText(for annotation: PDFAnnotation, on page: PDFPage) -> String {
        if let quads = annotation.quadrilateralPoints, quads.count >= 4 {
            let bounds = annotation.bounds
            var pieces: [String] = []
            var i = 0
            while i + 3 < quads.count {
                let pts = [quads[i], quads[i + 1], quads[i + 2], quads[i + 3]].map { $0.pointValue }
                let xs = pts.map { $0.x }
                let ys = pts.map { $0.y }
                guard let minX = xs.min(), let maxX = xs.max(),
                      let minY = ys.min(), let maxY = ys.max() else { i += 4; continue }
                // Quad points are relative to the annotation's bounds origin.
                let rect = CGRect(x: bounds.minX + minX,
                                  y: bounds.minY + minY,
                                  width: maxX - minX,
                                  height: maxY - minY)
                if let selection = page.selection(for: rect),
                   let s = selection.string, !s.isEmpty {
                    pieces.append(s)
                }
                i += 4
            }
            let joined = normalize(pieces.joined(separator: " "))
            if !joined.isEmpty { return joined }
        }

        if let selection = page.selection(for: annotation.bounds),
           let s = selection.string, !s.isEmpty {
            return normalize(s)
        }

        if let contents = annotation.contents, !contents.isEmpty {
            return normalize(contents)
        }

        return ""
    }

    private static func normalize(_ s: String) -> String {
        // Collapse hard line breaks and repeated whitespace introduced by PDF layout.
        let unwrapped = s.replacingOccurrences(of: "-\n", with: "")
            .replacingOccurrences(of: "\n", with: " ")
        let collapsed = unwrapped.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }
}
