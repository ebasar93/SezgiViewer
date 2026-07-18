import Foundation
import AppKit
import CoreText

/// Renders the combined highlights summary into a single clean PDF, styled to
/// resemble Apple's native document look (SF font, generous margins, thin dividers).
enum SummaryPDFGenerator {

    // Layout constants (US Letter).
    private static let pageSize = CGSize(width: 612, height: 792)
    private static let margin: CGFloat = 56
    private static let swatchSize: CGFloat = 11

    private static var contentWidth: CGFloat { pageSize.width - margin * 2 }

    // Palette approximating Apple's system semantics.
    private static let ink = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    private static let secondary = NSColor(srgbRed: 0.44, green: 0.44, blue: 0.46, alpha: 1)
    private static let divider = NSColor(srgbRed: 0.90, green: 0.90, blue: 0.92, alpha: 1)

    enum GeneratorError: Error { case couldNotCreateContext }

    /// Generates the summary PDF at `url`. Always a full, fresh render.
    static func generate(highlights: [Highlight],
                         generatedAt: Date,
                         to url: URL) throws {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw GeneratorError.couldNotCreateContext
        }

        let writer = PageWriter(ctx: ctx,
                                pageRect: mediaBox,
                                margin: margin,
                                background: .white)
        writer.beginPage()

        drawHeader(writer: writer, count: highlights.count, generatedAt: generatedAt)

        if highlights.isEmpty {
            drawEmptyState(writer: writer)
        } else {
            for (index, highlight) in highlights.enumerated() {
                drawEntry(highlight, writer: writer)
                if index < highlights.count - 1 {
                    writer.drawDivider(color: divider)
                }
            }
        }

        writer.endPage()
        ctx.closePDF()
    }

    // MARK: - Sections

    private static func drawHeader(writer: PageWriter, count: Int, generatedAt: Date) {
        let title = NSAttributedString(string: "Highlights Summary", attributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .bold),
            .foregroundColor: ink
        ])
        writer.drawSingleLine(title)
        writer.advance(by: 6)

        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .short
        let noun = count == 1 ? "highlight" : "highlights"
        let subtitle = NSAttributedString(string: "\(count) \(noun)  ·  Generated \(df.string(from: generatedAt))",
                                          attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: secondary
        ])
        writer.drawSingleLine(subtitle)
        writer.advance(by: 16)
        writer.drawDivider(color: divider)
        writer.advance(by: 6)
    }

    private static func drawEmptyState(writer: PageWriter) {
        let msg = NSAttributedString(string: "No highlights were found across the tracked PDFs.",
                                     attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: secondary
        ])
        writer.drawSingleLine(msg)
    }

    private static func drawEntry(_ highlight: Highlight, writer: PageWriter) {
        // Meta line: swatch + source name + (right-aligned) page & date.
        let source = NSAttributedString(string: highlight.sourceName, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: ink
        ])

        var metaBits: [String] = []
        if let label = highlight.pageLabel, !label.isEmpty {
            metaBits.append("p. \(label)")
        } else {
            metaBits.append("p. \(highlight.pageIndex + 1)")
        }
        if let date = highlight.date {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .none
            metaBits.append(df.string(from: date))
        }
        let meta = NSAttributedString(string: metaBits.joined(separator: "  ·  "), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: secondary
        ])

        writer.ensureSpace(for: 40)
        writer.drawMetaRow(swatchColor: highlight.color.nsColor,
                           swatchSize: swatchSize,
                           leading: source,
                           trailing: meta)
        writer.advance(by: 6)

        let body = NSAttributedString(string: highlight.text, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: ink,
            .paragraphStyle: bodyParagraphStyle
        ])
        writer.drawFlowingText(body)
        writer.advance(by: 14)
    }

    private static let bodyParagraphStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        p.paragraphSpacing = 0
        p.lineBreakMode = .byWordWrapping
        return p
    }()
}

/// Handles page geometry, page breaks, and the low-level drawing primitives.
/// Uses a top-down cursor (`y`) even though the underlying context is bottom-up.
final class PageWriter {
    private let ctx: CGContext
    private let pageRect: CGRect
    private let margin: CGFloat
    private let background: NSColor
    /// Distance from the top of the page down to the current cursor.
    private var y: CGFloat = 0
    private var pageOpen = false

    var contentWidth: CGFloat { pageRect.width - margin * 2 }
    private var leftX: CGFloat { margin }
    /// Remaining vertical space above the bottom margin.
    private var remaining: CGFloat { (pageRect.height - margin) - y }

    init(ctx: CGContext, pageRect: CGRect, margin: CGFloat, background: NSColor) {
        self.ctx = ctx
        self.pageRect = pageRect
        self.margin = margin
        self.background = background
    }

    func beginPage() {
        ctx.beginPDFPage(nil)
        ctx.setFillColor(background.cgColor)
        ctx.fill(pageRect)
        y = margin
        pageOpen = true
    }

    func endPage() {
        if pageOpen {
            ctx.endPDFPage()
            pageOpen = false
        }
    }

    private func newPage() {
        endPage()
        beginPage()
    }

    func advance(by amount: CGFloat) {
        y += amount
    }

    func ensureSpace(for height: CGFloat) {
        if remaining < height {
            newPage()
        }
    }

    /// Converts a top-down y offset to the context's bottom-up coordinate.
    private func flip(_ topY: CGFloat) -> CGFloat {
        pageRect.height - topY
    }

    func drawDivider(color: NSColor) {
        ensureSpace(for: 16)
        advance(by: 7)
        let lineY = flip(y)
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(0.75)
        ctx.move(to: CGPoint(x: leftX, y: lineY))
        ctx.addLine(to: CGPoint(x: leftX + contentWidth, y: lineY))
        ctx.strokePath()
        ctx.restoreGState()
        advance(by: 9)
    }

    /// Draws a single (non-wrapping) line at the cursor and advances.
    func drawSingleLine(_ attr: NSAttributedString) {
        let lineHeight = ceil(attr.size().height)
        ensureSpace(for: lineHeight)
        let baselineBottom = flip(y + lineHeight)
        withAppKitContext {
            attr.draw(at: CGPoint(x: leftX, y: baselineBottom))
        }
        advance(by: lineHeight)
    }

    /// Draws the swatch + leading label on the left and a trailing label on the right.
    func drawMetaRow(swatchColor: NSColor,
                     swatchSize: CGFloat,
                     leading: NSAttributedString,
                     trailing: NSAttributedString) {
        let lineHeight = ceil(max(leading.size().height, trailing.size().height))
        ensureSpace(for: lineHeight)
        let bottom = flip(y + lineHeight)

        // Swatch — rounded rect, vertically centered on the line.
        let swatchY = bottom + (lineHeight - swatchSize) / 2
        let swatchRect = CGRect(x: leftX, y: swatchY, width: swatchSize, height: swatchSize)
        let path = CGPath(roundedRect: swatchRect, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(swatchColor.cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.10).cgColor)
        ctx.setLineWidth(0.5)
        ctx.strokePath()
        ctx.restoreGState()

        let textX = leftX + swatchSize + 8
        withAppKitContext {
            leading.draw(at: CGPoint(x: textX, y: bottom))
            let trailingWidth = ceil(trailing.size().width)
            let trailingX = leftX + contentWidth - trailingWidth
            trailing.draw(at: CGPoint(x: trailingX, y: bottom))
        }
        advance(by: lineHeight)
    }

    /// Draws wrapping text, paginating across as many pages as needed.
    func drawFlowingText(_ attr: NSAttributedString) {
        let framesetter = CTFramesetterCreateWithAttributedString(attr as CFAttributedString)
        let total = attr.length
        var start = 0

        while start < total {
            if remaining < 24 { newPage() }
            let available = remaining
            let rect = CGRect(x: leftX, y: margin, width: contentWidth, height: available)
            let path = CGPath(rect: rect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter,
                                                 CFRangeMake(start, 0),
                                                 path, nil)

            ctx.saveGState()
            ctx.textMatrix = .identity
            CTFrameDraw(frame, ctx)
            ctx.restoreGState()

            let visible = CTFrameGetVisibleStringRange(frame)
            let usedHeight = measureUsedHeight(frame: frame, availableHeight: available)
            advance(by: usedHeight)

            if visible.length <= 0 {
                // Safety valve: nothing fit even on a fresh page — bail out.
                if start == 0 && remaining >= available { break }
                newPage()
                continue
            }
            start += visible.length

            if start < total {
                newPage()
            }
        }
    }

    /// Measures how much vertical space the drawn frame actually consumed.
    private func measureUsedHeight(frame: CTFrame, availableHeight: CGFloat) -> CGFloat {
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        guard !lines.isEmpty else { return 0 }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), &origins)

        let lastOrigin = origins[origins.count - 1]
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(lines[lines.count - 1], &ascent, &descent, &leading)

        // Origins are relative to the rect's bottom-left; the frame's top sits at
        // `availableHeight`. Used height = top down to the last line's descent.
        let used = availableHeight - (lastOrigin.y - descent)
        return min(max(used, 0), availableHeight) + 2
    }

    private func withAppKitContext(_ body: () -> Void) {
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = ns
        body()
        NSGraphicsContext.current = previous
    }
}
