//
//  Charts.swift
//  Lightweight sparkline charts (no external dependency, macOS 12 compatible).
//

import SwiftUI

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

    private var bounds: ClosedRange<Double> {
        if let range { return range }
        let values = points.map { $0.value }
        guard let min = values.min(), let max = values.max(), max > min else { return 0...100 }
        let pad = (max - min) * 0.25 + 0.5
        return (min - pad)...(max + pad)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(theme.textSecondary)
                Spacer(minLength: 4)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10))
                        .foregroundColor(theme.textTertiary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(valueText)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundColor(theme.textPrimary)
                if let caption {
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundColor(theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            GeometryReader { geo in
                ZStack {
                    // baseline grid
                    VStack(spacing: 0) {
                        ForEach(0..<4, id: \.self) { _ in
                            Rectangle().fill(theme.divider).frame(height: 1)
                            Spacer(minLength: 0)
                        }
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
            .frame(height: 74)
            .clipped()
        }
    }

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
