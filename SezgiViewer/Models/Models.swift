import Foundation
import AppKit
import SwiftUI

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
