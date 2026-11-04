//
//  Charts.swift
//  Lightweight sparkline charts (no external dependency, macOS 12 compatible).
//

import SwiftUI

/// A sparkline with just enough axis to be read: three value ticks down the
/// right edge (top / middle / bottom of the drawn range) and the first, middle
/// and last timestamp underneath. Without them the curve said "something moved"
/// but neither the scale nor the time span could be recovered from the card.
struct MiniChart: View {
    private var theme: Theme { Theme.current }
    let title: String
    let valueText: String
    /// Secondary line under the value (e.g. "剩余 4 小时 39 分").
    var caption: String? = nil
    var symbol: String? = nil
    var color: Color = .green
    var points: [HistoryPoint]
    var limitFraction: Double? = nil
    var range: ClosedRange<Double>? = nil

    private let plotHeight: CGFloat = 74
    /// Room for a four-digit tick at `micro`, right-aligned against the plot.
    private let axisWidth: CGFloat = 34

    private var bounds: ClosedRange<Double> {
        if let range { return range }
        let values = points.map { $0.value }
        guard let min = values.min(), let max = values.max() else { return 0...100 }
        // A flat line has no range of its own. Falling back to 0…100 labelled a
        // steady 33 °C axis "100 / 50 / 0"; a window around the reading keeps
        // the ticks meaningful.
        guard max > min else {
            let pad = Swift.max(abs(min) * 0.05, 0.5)
            return (min - pad)...(min + pad)
        }
        let pad = (max - min) * 0.25 + 0.5
        return (min - pad)...(max + pad)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
                Spacer(minLength: 4)
                if let symbol {
                    Image(systemName: symbol)
                        .font(Glyph.inline)
                        .foregroundColor(theme.textTertiary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(valueText)
                    .font(Typography.title.monospacedDigit())
                    .foregroundColor(theme.textPrimary)
                if let caption {
                    Text(caption)
                        .font(Typography.caption)
                        .foregroundColor(theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(alignment: .top, spacing: 6) {
                plot.frame(height: plotHeight)
                tickColumn.frame(width: axisWidth, height: plotHeight)
            }
            // Full width, not just the plot: three timestamps do not fit in the
            // ~125 pt the plot has left over once the ticks take their gutter,
            // and truncating them to "20:12:…" is worse than overhanging it.
            timeAxis
        }
    }

    // MARK: - plot

    private var plot: some View {
        GeometryReader { geo in
            ZStack {
                // Three lines, matching the three ticks: 0 / 50 / 100 % of the
                // drawn range.
                VStack(spacing: 0) {
                    gridLine
                    Spacer(minLength: 0)
                    gridLine
                    Spacer(minLength: 0)
                    gridLine
                }
                if let limitFraction {
                    let y = geo.size.height * (1 - limitFraction)
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundColor(theme.textTertiary)
                }
                if points.count > 1 {
                    let path = linePath(size: geo.size)
                    path
                        .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    fillPath(path: path, size: geo.size)
                        .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)],
                                             startPoint: .top, endPoint: .bottom))
                } else {
                    Rectangle().fill(theme.divider.opacity(0.35))
                }
            }
        }
        .clipped()
    }

    private var gridLine: some View {
        Rectangle().fill(theme.divider).frame(height: 1)
    }

    /// Three labels against the three grid lines. The outer two sit half a line
    /// height inside their row, which is the closest a text baseline gets to an
    /// exact grid line without clipping the glyphs.
    private var tickColumn: some View {
        VStack(alignment: .trailing, spacing: 0) {
            tick(bounds.upperBound).frame(maxHeight: .infinity, alignment: .top)
            tick((bounds.upperBound + bounds.lowerBound) / 2)
                .frame(maxHeight: .infinity, alignment: .center)
            tick(bounds.lowerBound).frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func tick(_ value: Double) -> some View {
        Text(String(format: "%.0f", value))
            .font(Typography.micro)
            .foregroundColor(theme.textTertiary)
            .fixedSize()
    }

    private var timeAxis: some View {
        HStack(spacing: 0) {
            Text(timeText(at: 0))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(timeText(at: points.count / 2))
                .frame(maxWidth: .infinity, alignment: .center)
            Text(timeText(at: points.count - 1))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(Typography.micro)
        .foregroundColor(theme.textTertiary)
        .lineLimit(1)
    }

    private func timeText(at index: Int) -> String {
        guard points.count > 1, points.indices.contains(index) else { return "" }
        let formatter = span < 120 ? Self.clockSeconds : Self.clockMinutes
        return formatter.string(from: points[index].date)
    }

    private var span: TimeInterval {
        guard let first = points.first, let last = points.last else { return 0 }
        return last.date.timeIntervalSince(first.date)
    }

    private static let clockMinutes = clock("HH:mm")
    private static let clockSeconds = clock("HH:mm:ss")

    /// Minutes alone collapse to the same label three times when the buffer is
    /// younger than a minute, so a young window is labelled to the second.
    private static func clock(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    // MARK: - geometry

    private func normalized(_ value: Double, _ size: CGSize) -> CGFloat {
        let lower = bounds.lowerBound
        let upper = bounds.upperBound
        let fraction = upper > lower ? (value - lower) / (upper - lower) : 0.5
        return size.height * (1 - CGFloat(min(max(fraction, 0), 1)))
    }

    private func linePath(size: CGSize) -> Path {
        var path = Path()
        let step = size.width / CGFloat(max(1, points.count - 1))
        for (index, point) in points.enumerated() {
            let x = step * CGFloat(index)
            let y = normalized(point.value, size)
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }

    private func fillPath(path: Path, size: CGSize) -> Path {
        var filled = path
        filled.addLine(to: CGPoint(x: size.width, y: size.height))
        filled.addLine(to: CGPoint(x: 0, y: size.height))
        filled.closeSubpath()
        return filled
    }
}
