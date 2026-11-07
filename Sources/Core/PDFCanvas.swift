//
//  PDFCanvas.swift
//  A very small page painter: a cursor, three text styles, a table and a
//  polyline. Everything the battery report needs and nothing else.
//
//  Core Graphics + Core Text rather than `ImageRenderer`: this app supports
//  macOS 12 and `ImageRenderer` needs 13, and a vector PDF stays sharp at any
//  zoom where a rendered bitmap does not. Core Text also embeds the system
//  Chinese font, so no glyph turns into a box.
//

import Foundation
import CoreGraphics
import CoreText
import AppKit

// MARK: - Layout

/// A small, deliberately dumb page painter: a cursor, three text styles and a
/// page break. Everything above it is content.
final class PDFCanvas {

    struct Style {
        var size: CGFloat
        var weight: NSFont.Weight = .regular
        /// Fixed ink, never a dynamic system colour. The app runs in dark mode
        /// most of the time, where `labelColor` resolves to near-white — on
        /// white paper that is invisible text, which is exactly what the first
        /// render produced.
        var color: NSColor = NSColor(white: 0.08, alpha: 1)
        var lineSpacing: CGFloat = 2

        static let secondary = NSColor(white: 0.42, alpha: 1)
    }

    static let pageSize = CGSize(width: 595, height: 842) // A4, 72 dpi
    static let margin: CGFloat = 44

    private let context: CGContext
    private(set) var page = 0
    var y: CGFloat = 0

    init(context: CGContext) {
        self.context = context
        beginPage()
    }

    private var contentWidth: CGFloat { Self.pageSize.width - Self.margin * 2 }
    private var bottom: CGFloat { Self.margin + 34 }

    private func beginPage() {
        page += 1
        context.beginPDFPage(nil)
        // White paper regardless of the app's dark theme: this document is
        // going to be printed or attached to an email.
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: Self.pageSize))
        y = Self.pageSize.height - Self.margin
    }

    func newPageIfNeeded(_ height: CGFloat) {
        if y - height < bottom {
            endPage()
            beginPage()
        }
    }

    /// Explicit break. Used between the two halves of the report so the
    /// document always has the same shape: overview and trend first, records
    /// and habits second. Letting it flow produced a second page with two
    /// headings and 500 pt of nothing.
    func pageBreak() {
        endPage()
        beginPage()
    }

    func endPage() {
        // The footer is per page: a printed stack has to be reassemblable.
        let footer = "InfiniCal \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · \(page)"
        draw(footer, style: Style(size: 8, color: PDFCanvas.Style.secondary),
             rect: CGRect(x: Self.margin, y: Self.margin - 12, width: contentWidth, height: 12),
             alignment: .right)
        context.endPDFPage()
    }

    func finish() {
        endPage()
        context.closePDF()
    }

    // MARK: Text

    @discardableResult
    func text(_ string: String, style: Style, gapAfter: CGFloat = 4,
              alignment: NSTextAlignment = .left) -> CGFloat {
        let attributed = attributedString(string, style: style, alignment: alignment)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let width = contentWidth
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        let height = ceil(suggested.height) + 2
        newPageIfNeeded(height)
        let rect = CGRect(x: Self.margin, y: y - height, width: width, height: height)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        context.saveGState()
        CTFrameDraw(frame, context)
        context.restoreGState()
        y -= height + gapAfter
        return height
    }

    func heading(_ string: String, gapAfter: CGFloat = 8) {
        newPageIfNeeded(60)
        y -= 6
        text(string, style: Style(size: 13, weight: .semibold), gapAfter: gapAfter)
    }

    func rule() {
        newPageIfNeeded(12)
        context.setStrokeColor(NSColor(white: 0.85, alpha: 1).cgColor)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: Self.margin, y: y - 4))
        context.addLine(to: CGPoint(x: Self.pageSize.width - Self.margin, y: y - 4))
        context.strokePath()
        y -= 12
    }

    /// Two columns: label left, value right. The shape of every specification
    /// row in the app.
    func pair(_ label: String, _ value: String, gapAfter: CGFloat = 3) {
        let height: CGFloat = 15
        newPageIfNeeded(height)
        draw(label, style: Style(size: 10, color: PDFCanvas.Style.secondary),
             rect: CGRect(x: Self.margin, y: y - height, width: contentWidth * 0.55, height: height),
             alignment: .left)
        draw(value, style: Style(size: 10),
             rect: CGRect(x: Self.margin, y: y - height, width: contentWidth, height: height),
             alignment: .right)
        y -= height + gapAfter
    }

    /// A horizontal bar for one number against a maximum. Used for the health
    /// and capacity comparison, where a number alone hides the magnitude.
    func bar(fraction: Double, label: String, value: String, tint: NSColor) {
        let height: CGFloat = 18
        newPageIfNeeded(height + 4)
        draw(label, style: Style(size: 9, color: PDFCanvas.Style.secondary),
             rect: CGRect(x: Self.margin, y: y - 12, width: 160, height: 12), alignment: .left)
        draw(value, style: Style(size: 9),
             rect: CGRect(x: Self.margin, y: y - 12, width: contentWidth, height: 12), alignment: .right)
        let trackWidth = contentWidth
        let track = CGRect(x: Self.margin, y: y - height, width: trackWidth, height: 5)
        context.setFillColor(NSColor(white: 0.92, alpha: 1).cgColor)
        context.fill(track)
        let width = trackWidth * CGFloat(min(1, max(0, fraction)))
        context.setFillColor(tint.cgColor)
        context.fill(CGRect(x: track.minX, y: track.minY, width: width, height: 5))
        y -= height + 6
    }

    /// Fixed-width columns, one header row and body rows. Every column shares
    /// the width equally except the first, which holds a timestamp.
    func table(_ header: [String], rows: [[String]], firstColumnWidth: CGFloat = 90) {
        let rowHeight: CGFloat = 16
        newPageIfNeeded(rowHeight * CGFloat(rows.count + 1) + 8)
        let otherWidth = (contentWidth - firstColumnWidth) / CGFloat(max(1, header.count - 1))
        func drawRow(_ cells: [String], bold: Bool, color: NSColor) {
            for (index, cell) in cells.enumerated() {
                let x = index == 0 ? Self.margin
                    : Self.margin + firstColumnWidth + otherWidth * CGFloat(index - 1)
                let width = index == 0 ? firstColumnWidth : otherWidth
                let alignment: NSTextAlignment = index == 0 ? .left : .right
                draw(cell, style: Style(size: 8.5, weight: bold ? .medium : .regular, color: color),
                     rect: CGRect(x: x, y: y - rowHeight + 3, width: width - 6, height: rowHeight),
                     alignment: alignment)
            }
            y -= rowHeight
        }
        drawRow(header, bold: true, color: Style.secondary)
        context.setStrokeColor(NSColor(white: 0.85, alpha: 1).cgColor)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: Self.margin, y: y + 1))
        context.addLine(to: CGPoint(x: Self.pageSize.width - Self.margin, y: y + 1))
        context.strokePath()
        for row in rows { drawRow(row, bold: false, color: NSColor(white: 0.25, alpha: 1)) }
        y -= 8
    }

    /// Polyline of `values` normalised into `range`.
    func line(values: [Double], range: ClosedRange<Double>, height: CGFloat = 90,
              tint: NSColor = .systemBlue, caption: String? = nil) {
        newPageIfNeeded(height + 24)
        let rect = CGRect(x: Self.margin, y: y - height, width: contentWidth, height: height)
        context.setStrokeColor(NSColor(white: 0.88, alpha: 1).cgColor)
        context.setLineWidth(0.5)
        for index in 0...2 {
            let lineY = rect.minY + height * CGFloat(index) / 2
            context.move(to: CGPoint(x: rect.minX, y: lineY))
            context.addLine(to: CGPoint(x: rect.maxX, y: lineY))
        }
        context.strokePath()

        guard values.count >= 2, range.upperBound > range.lowerBound else {
            draw("--", style: Style(size: 9, color: PDFCanvas.Style.secondary),
                 rect: rect, alignment: .center)
            y -= height + 6
            return
        }
        let span = range.upperBound - range.lowerBound
        context.setStrokeColor(tint.cgColor)
        context.setLineWidth(1.4)
        for (index, value) in values.enumerated() {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1)
            let normalized = (value - range.lowerBound) / span
            let point = CGPoint(x: x, y: rect.minY + rect.height * CGFloat(normalized))
            index == 0 ? context.move(to: point) : context.addLine(to: point)
        }
        context.strokePath()
        if let caption {
            draw(caption, style: Style(size: 8, color: PDFCanvas.Style.secondary),
                 rect: CGRect(x: rect.minX, y: rect.minY - 10, width: rect.width, height: 10),
                 alignment: .left)
        }
        y -= height + 16
    }

    // MARK: Primitives

    private func attributedString(_ string: String, style: Style,
                                  alignment: NSTextAlignment) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineSpacing = style.lineSpacing
        let font = NSFont.systemFont(ofSize: style.size, weight: style.weight)
        return NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: style.color, .paragraphStyle: paragraph
        ])
    }

    private func draw(_ string: String, style: Style, rect: CGRect, alignment: NSTextAlignment) {
        let attributed = attributedString(string, style: style, alignment: alignment)
        let frame = CTFramesetterCreateFrame(
            CTFramesetterCreateWithAttributedString(attributed),
            CFRange(location: 0, length: 0),
            CGPath(rect: rect, transform: nil), nil)
        context.saveGState()
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}

