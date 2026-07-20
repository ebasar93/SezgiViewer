import Foundation
import AppKit
import SwiftUI
import CryptoKit

/// An sRGB color with alpha, stored so highlight colors survive across launches.
struct RGBAColor: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Builds from an `NSColor`, normalizing into the sRGB color space.
    init?(nsColor: NSColor) {
        guard let c = nsColor.usingColorSpace(.sRGB) else { return nil }
        self.red = Double(c.redComponent)
        self.green = Double(c.greenComponent)
        self.blue = Double(c.blueComponent)
        self.alpha = Double(c.alphaComponent)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1.0)
    }

    /// A rough human-readable name for the color, used for the color filter menu.
    var approximateName: String {
        let (h, s, b) = hsb
        if s < 0.12 {
            if b > 0.85 { return "White" }
            if b < 0.25 { return "Black" }
            return "Gray"
        }
        switch h * 360 {
        case ..<20, 340...: return "Red"
        case ..<45: return "Orange"
        case ..<70: return "Yellow"
        case ..<160: return "Green"
        case ..<200: return "Cyan"
        case ..<255: return "Blue"
        case ..<290: return "Purple"
        default: return "Pink"
        }
    }

    private var hsb: (Double, Double, Double) {
        let maxV = max(red, green, blue)
        let minV = min(red, green, blue)
        let delta = maxV - minV
        var h = 0.0
        if delta != 0 {
            if maxV == red {
                h = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxV == green {
                h = (blue - red) / delta + 2
            } else {
                h = (red - green) / delta + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        let s = maxV == 0 ? 0 : delta / maxV
        return (h, s, maxV)
    }
}

/// A single extracted highlight annotation.
struct Highlight: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// The record id of the source PDF this highlight came from.
    var sourceID: UUID
    var sourceName: String
    var text: String
    var color: RGBAColor
    var pageIndex: Int
    var pageLabel: String?
    var date: Date?

    init(id: UUID = UUID(),
         sourceID: UUID,
         sourceName: String,
         text: String,
         color: RGBAColor,
         pageIndex: Int,
         pageLabel: String? = nil,
         date: Date? = nil) {
        self.id = id
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.text = text
        self.color = color
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.date = date
    }
}

extension Highlight {
    /// Stable identity across re-scans. `id` is regenerated every time a file is
    /// parsed, so anything that must survive a refresh (app-side deletion,
    /// combining) references this content-derived fingerprint instead. If the
    /// underlying annotation changes in the source PDF, the fingerprint changes
    /// and any deletion/combination referencing it is naturally released.
    var fingerprint: String {
        let colorKey = String(format: "%.3f,%.3f,%.3f", color.red, color.green, color.blue)
        let canonical = "\(sourceID.uuidString)|\(pageIndex)|\(colorKey)|\(text)"
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Availability / parse status of a tracked file, recomputed on every refresh.
enum FileStatus: String, Codable, Sendable {
    case ok          // parsed, has highlights (or unchanged with cached highlights)
    case empty       // parsed successfully, zero highlights
    case missing     // file could not be located
    case unreadable  // corrupted or password-protected
    case unscanned   // added but not yet scanned
}

/// A PDF the user is tracking in the project. Persisted between launches.
struct TrackedPDF: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var displayName: String
    /// Security-scoped bookmark so the file stays accessible after relaunch.
    var bookmark: Data
    /// Last-known filesystem modification date at time of last successful scan.
    var lastModified: Date?
    /// Highlights cached from the last successful parse.
    var cachedHighlights: [Highlight]
    var status: FileStatus
    /// Last resolved path, shown in the UI (may be stale if the file moved).
    var lastKnownPath: String
    /// Whether this file's highlights are included in the aggregated list / export.
    var isSelected: Bool

    init(id: UUID = UUID(),
         displayName: String,
         bookmark: Data,
         lastModified: Date? = nil,
         cachedHighlights: [Highlight] = [],
         status: FileStatus = .unscanned,
         lastKnownPath: String = "",
         isSelected: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.bookmark = bookmark
        self.lastModified = lastModified
        self.cachedHighlights = cachedHighlights
        self.status = status
        self.lastKnownPath = lastKnownPath
        self.isSelected = isSelected
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, bookmark, lastModified, cachedHighlights
        case status, lastKnownPath, isSelected
    }

    // Custom decoding so projects saved before `isSelected` existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        bookmark = try c.decode(Data.self, forKey: .bookmark)
        lastModified = try c.decodeIfPresent(Date.self, forKey: .lastModified)
        cachedHighlights = try c.decodeIfPresent([Highlight].self, forKey: .cachedHighlights) ?? []
        status = try c.decodeIfPresent(FileStatus.self, forKey: .status) ?? .unscanned
        lastKnownPath = try c.decodeIfPresent(String.self, forKey: .lastKnownPath) ?? ""
        isSelected = try c.decodeIfPresent(Bool.self, forKey: .isSelected) ?? true
    }

    /// Highlights that should appear in the combined output.
    var exportableHighlights: [Highlight] {
        (isSelected && status == .ok) ? cachedHighlights : []
    }
}

/// A user-created combination of several highlights into one entry.
/// Members are referenced by fingerprint so the group survives re-scans;
/// members may come from different source PDFs.
struct HighlightGroup: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// Fingerprints of the member highlights, in display order.
    var memberFingerprints: [String]

    init(id: UUID = UUID(), memberFingerprints: [String]) {
        self.id = id
        self.memberFingerprints = memberFingerprints
    }
}

/// One row of the aggregated list: either a single highlight or a combined
/// group of them. Built fresh on every rebuild; not persisted itself.
struct HighlightEntry: Identifiable, Hashable, Sendable {
    let id: String
    /// Non-nil when this entry is a combined group.
    let groupID: UUID?
    /// Always at least one; order is display order.
    let members: [Highlight]

    var isCombined: Bool { members.count > 1 }
    var primary: Highlight { members[0] }

    /// Member texts joined for display/export/length-sorting.
    var combinedText: String {
        members.map(\.text).joined(separator: "\n")
    }

    /// Unique source names in member order.
    var sourceNames: [String] {
        var seen: [String] = []
        for m in members where !seen.contains(m.sourceName) { seen.append(m.sourceName) }
        return seen
    }

    /// Unique page labels in member order (e.g. ["3", "12"]).
    var pageLabels: [String] {
        var seen: [String] = []
        for m in members {
            let label = m.pageLabel ?? "\(m.pageIndex + 1)"
            if !seen.contains(label) { seen.append(label) }
        }
        return seen
    }

    /// Unique member colors in order, for the swatch stack.
    var colors: [RGBAColor] {
        var seen: [RGBAColor] = []
        for m in members where !seen.contains(m.color) { seen.append(m.color) }
        return seen
    }
}

/// Which metadata is shown per highlight, in both the list and the exported PDF.
struct DisplayOptions: Codable, Hashable, Sendable {
    var showPage: Bool = true
    var showSource: Bool = true
    var showDate: Bool = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case showPage, showSource, showDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showPage = try c.decodeIfPresent(Bool.self, forKey: .showPage) ?? true
        showSource = try c.decodeIfPresent(Bool.self, forKey: .showSource) ?? true
        showDate = try c.decodeIfPresent(Bool.self, forKey: .showDate) ?? true
    }
}

/// How the aggregated highlight list is ordered.
enum HighlightSort: String, CaseIterable, Codable, Sendable {
    case sourceOrder
    case dateDescending
    case dateAscending
    case lengthDescending
    case lengthAscending

    var label: String {
        switch self {
        case .sourceOrder: return "File Order"
        case .dateDescending: return "Date (Newest First)"
        case .dateAscending: return "Date (Oldest First)"
        case .lengthDescending: return "Length (Longest First)"
        case .lengthAscending: return "Length (Shortest First)"
        }
    }

    var systemImage: String {
        switch self {
        case .sourceOrder: return "list.bullet"
        case .dateDescending: return "calendar.badge.clock"
        case .dateAscending: return "calendar"
        case .lengthDescending: return "arrow.down.right.and.arrow.up.left"
        case .lengthAscending: return "arrow.up.left.and.arrow.down.right"
        }
    }

    /// Returns a sorted copy. `sourceOrder` preserves the incoming order.
    func apply(to highlights: [Highlight]) -> [Highlight] {
        switch self {
        case .sourceOrder:
            return highlights
        case .dateDescending:
            return highlights.sorted { lhs, rhs in
                switch (lhs.date, rhs.date) {
                case let (l?, r?): return l > r
                case (nil, _?): return false   // undated sinks to the bottom
                case (_?, nil): return true
                case (nil, nil): return false
                }
            }
        case .dateAscending:
            return highlights.sorted { lhs, rhs in
                switch (lhs.date, rhs.date) {
                case let (l?, r?): return l < r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return false
                }
            }
        case .lengthDescending:
            return highlights.sorted { $0.text.count > $1.text.count }
        case .lengthAscending:
            return highlights.sorted { $0.text.count < $1.text.count }
        }
    }
}
