//
//  PowerFlowView.swift
//  Animated Sankey power flow.
//
//  Every node size, ribbon thickness, particle speed and label is driven by a
//  measured watt value. Values this macOS build does not expose to user space
//  (SoC / display energy counters) are labelled as estimates instead of being
//  invented.
//
//  Readability rules baked into this view:
//  * numbers always carry exactly one decimal (PowerFormat.watts),
//  * the text of a number is published at most every 1.2 s (FlowTicker.shown*),
//    so digits stop flickering while the geometry still glides at 30 fps,
//  * three columns only — figure (1), ribbons (2), legend (1): the total on the
//    left, one legend row per branch on the right, and no label floating over
//    the curves.
//

import SwiftUI

// MARK: - Model

struct PowerFlowSink: Identifiable {
    enum Kind: String {
        case display, soc, battery, usb, other
    }

    var id: String { kind.rawValue }
    var kind: Kind
    var title: String
    var symbol: String
    var color: Color
    var watts: Double?
    var quality: PowerQuality = .measured
    var detail: String?
}

struct PowerFlowModel {
    enum Source {
        case adapter
        case battery
    }

    var source: Source
    var sourcePower: Double
    var sourceDetail: String
    var systemPower: Double
    var sinks: [PowerFlowSink]


    static func make(from snapshot: BatterySnapshot,
                     liveTotal: Double,
                     totalIsLive: Bool = true,
                     soc: PowerReading,
                     display: PowerReading,
                     usb: PowerReading = .unavailable) -> PowerFlowModel {
        let plugged = snapshot.isPluggedIn
        let batteryWatts = snapshot.voltage * snapshot.amperage      // > 0 charging, < 0 discharging

        // Estimates must never exceed what the measured total can supply:
        // cap SoC + display at 80 % of the available power so "其他" keeps a
        // believable share instead of collapsing to zero.
        var display = display
        var soc = soc
        let totalPower = liveTotal > 0.01 ? liveTotal : snapshot.systemLoad
        let available = max(0, totalPower - max(0, batteryWatts))
        let estimateSum = (display.watts ?? 0) + (soc.watts ?? 0)
        if estimateSum > available * 0.8, available > 0 {
            let scale = available * 0.8 / estimateSum
            if let value = display.watts {
                let scaled = value * scale
                display = PowerReading(watts: scaled, quality: display.quality,
                                       note: (display.note ?? "") + String(format: t("（按总量约束缩放 ×%.2f）"), scale))
            }
            if let value = soc.watts {
                let scaled = value * scale
                soc = PowerReading(watts: scaled, quality: soc.quality,
                                   note: (soc.note ?? "") + String(format: t("（按总量约束缩放 ×%.2f）"), scale))
            }
        }

        var sinks: [PowerFlowSink] = []
        if let watts = display.watts {
            sinks.append(PowerFlowSink(kind: .display, title: t("显示"), symbol: "display",
                                       color: Theme.current.flowSystem,
                                       watts: watts, quality: display.quality, detail: display.note))
        }
        if let watts = soc.watts {
            sinks.append(PowerFlowSink(kind: .soc, title: "SoC", symbol: "cpu",
                                       color: Theme.current.flowSoC,
                                       watts: watts, quality: soc.quality, detail: soc.note))
        }
        if plugged {
            let charge = max(0, batteryWatts)
            sinks.append(PowerFlowSink(kind: .battery, title: t("电池"), symbol: "battery.100.bolt",
                                       color: Theme.current.flowBattery,
                                       watts: charge, quality: .measured,
                                       detail: charge < 0.05 ? t("未充电") : t("充电中")))
        }
        if let watts = usb.watts {
            sinks.append(PowerFlowSink(kind: .usb, title: "USB", symbol: "cable.connector",
                                       color: Theme.current.flowUSB,
                                       watts: watts, quality: usb.quality, detail: usb.note))
        }

        // "其他" is by definition `system total − known system sinks`. The pack
        // is fed by the adapter, not by the logic board, so it must not be
        // subtracted from the system budget: doing so made the residual collapse
        // to zero and printed "其他 —" whenever the machine was charging.
        let systemKnown = sinks.filter { $0.kind != .battery }.compactMap { $0.watts }.reduce(0, +)
        // That subtraction is only honest
        // while the total comes from a live sample: before PSTR produces its first
        // sane value we fall back to the 60-second snapshot, which can be 20 W off,
        // and the residual would then be a fabricated number.
        let other = (totalIsLive && totalPower >= 3) ? max(0, totalPower - systemKnown) : 0
        let hasEstimate = sinks.contains { $0.quality == .estimated }
        sinks.append(PowerFlowSink(kind: .other, title: t("其他"), symbol: "ellipsis",
                                   color: Theme.current.flowOther,
                                   watts: other, quality: .measured,
                                   detail: hasEstimate ? t("总数 − 已知分项（含估算误差）") : t("总数 − 已知分项")))

        // PSTR / SystemLoad measure what the logic board draws, not what the
        // adapter delivers. While the pack is charging the adapter has to supply
        // both, so the source node is their sum — otherwise it prints less than
        // the sum of its own ribbons (17.7 W against 42 W of sinks).
        let chargeIntoBattery = max(0, batteryWatts)
        let sourcePower = totalPower + chargeIntoBattery
        let systemOnly = totalPower
        let detail: String
        if plugged {
            detail = snapshot.adapter.isEmpty ? t("电源适配器") : snapshot.adapter.name
        } else {
            detail = t("电池供电")
        }

        return PowerFlowModel(source: plugged ? .adapter : .battery,
                              sourcePower: sourcePower,
                              sourceDetail: detail,
                              systemPower: systemOnly,
                              sinks: sinks)
    }
}

// MARK: - Animation driver

/// Drives the animation clock and holds two kinds of values:
///
/// * `smoothed*` – 30 fps exponential smoothing, used for geometry only.
/// * `shown*`    – throttled, quantised snapshot used for every printed number.
///
/// Splitting them is what stops the digits from churning several times per
/// second while the ribbons keep moving smoothly.
final class FlowTicker: ObservableObject {
    /// 0..1 looping phase used for particle travel and glow sweeps.
    @Published var phase: Double = 0
    /// Geometry values (smooth, 30 fps).
    @Published var smoothedSource: Double = 0
    @Published var smoothedSystem: Double = 0
    @Published var smoothedSinks: [String: Double] = [:]
    /// Printed values (throttled to one update per `publishInterval`).
    @Published var shownSource: Double = 0
    @Published var shownSystem: Double = 0
    @Published var shownSinks: [String: Double] = [:]

    /// Seconds between two text updates. The printed value is the *average* over
    /// this window, which is what makes the digits hold still: the raw SMC sample
    /// swings by a watt or two every second, but its 2 s mean barely moves.
    private let publishInterval: Double = 2.0
    /// A printed value only changes when it moves at least this much (W).
    private let deadband: Double = 0.2

    private var timer: Timer?
    private var targetSource: Double = 0
    private var targetSystem: Double = 0
    private var targetSinks: [String: Double] = [:]
    private var lastTick = Date()
    private var lastPublish = Date.distantPast
    /// Running sums used to produce the window average at each publish.
    private var sourceSum: Double = 0
    private var systemSum: Double = 0
    private var sinkSums: [String: Double] = [:]
    private var sampleCount: Double = 0

    func update(_ model: PowerFlowModel) {
        targetSource = model.sourcePower
        targetSystem = model.systemPower
        var sinks: [String: Double] = [:]
        for sink in model.sinks { sinks[sink.id] = sink.watts ?? 0 }
        targetSinks = sinks

        // Seed the printed values on the first model so the very first frame
        // already shows text instead of falling back to raw geometry.
        if sampleCount == 0, shownSource == 0, shownSinks.isEmpty {
            shownSource = (model.sourcePower * 10).rounded() / 10
            shownSystem = (model.systemPower * 10).rounded() / 10
            for (key, value) in sinks { shownSinks[key] = (value * 10).rounded() / 10 }
        }
    }

    func start() {
        guard timer == nil else { return }
        lastTick = Date()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = Date()
        let dt = min(0.1, now.timeIntervalSince(lastTick))
        lastTick = now
        // ~0.55 s time constant: fast enough to feel live, slow enough that the
        // ribbons do not twitch on every 1 Hz SMC sample.
        let k = 1 - exp(-dt * 1.8)

        smoothedSource += (targetSource - smoothedSource) * k
        smoothedSystem += (targetSystem - smoothedSystem) * k
        for (key, target) in targetSinks {
            let current = smoothedSinks[key] ?? target
            smoothedSinks[key] = current + (target - current) * k
        }

        // Accumulate the smoothed signal so each publish can print its mean.
        sourceSum += smoothedSource
        systemSum += smoothedSystem
        for (key, value) in smoothedSinks { sinkSums[key, default: 0] += value }
        sampleCount += 1

        // Travel speed follows the load: a 30 W flow moves visibly faster than 2 W.
        let load = max(0.5, smoothedSystem)
        phase += dt * (0.14 + min(0.42, load / 60.0))
        if phase > 1 { phase -= 1 }

        if now.timeIntervalSince(lastPublish) >= publishInterval {
            lastPublish = now
            publish()
        }
    }

    /// Prints the window mean, quantised to one decimal, and only when it has
    /// actually moved — a value hovering on a rounding boundary stays put.
    private func publish() {
        let count = max(1, sampleCount)
        shownSource = quantise(shownSource, sourceSum / count)
        shownSystem = quantise(shownSystem, systemSum / count)
        for (key, sum) in sinkSums where key != "other" {
            shownSinks[key] = quantise(shownSinks[key] ?? sum / count, sum / count)
        }
        // Drop entries for branches that no longer exist so a stale watt can
        // never resurface in the header chips.
        for key in shownSinks.keys where sinkSums[key] == nil {
            shownSinks.removeValue(forKey: key)
        }
        // "其他" is a residual by definition, so derive it from the same printed
        // values that are on screen — including the printed total. Every number a
        // user can add up therefore closes exactly, with no hidden rounding gap.
        let known = ["display", "soc", "battery", "usb"]
            .compactMap { shownSinks[$0] }
            .reduce(0, +)
        let residual = max(0, shownSource - known)
        shownSinks["other"] = (residual * 10).rounded() / 10
        sourceSum = 0
        systemSum = 0
        sinkSums.removeAll(keepingCapacity: true)
        sampleCount = 0
    }

    private func quantise(_ previous: Double, _ next: Double) -> Double {
        guard next.isFinite else { return previous }
        let rounded = (next * 10).rounded() / 10
        return abs(rounded - previous) >= deadband ? rounded : previous
    }
}

// MARK: - View

struct PowerFlowView: View {
    private var theme: Theme { Theme.current }

    var model: PowerFlowModel
    @ObservedObject var ticker: FlowTicker
    var compact: Bool = false

    private struct Placed {
        var sink: PowerFlowSink
        /// Ribbon geometry — thickness is proportional to the measured watts.
        var startTop: CGFloat
        var startBottom: CGFloat
        var endTop: CGFloat
        var endBottom: CGFloat
        /// Legend row geometry — a fixed height, so a 6 W branch and a 60 W
        /// branch line up on the same grid instead of stretching with their
        /// value.
        var rowTop: CGFloat
        var rowHeight: CGFloat
    }

    private struct Layout {
        var placed: [Placed]
        var sourceW: CGFloat
        var sourceH: CGFloat
        var sourceY: CGFloat
        var ribbonStart: CGFloat
        var ribbonEnd: CGFloat
        var rowW: CGFloat
    }

    // MARK: geometry

    private func compute(_ size: CGSize) -> Layout {
        let w = size.width
        let h = size.height
        // The card already supplies a 14 pt inset, so padding again here showed
        // up as a dead frame inside the card. The diagram now starts at the
        // card's content edge and uses the whole width.
        let gap: CGFloat = compact ? 8 : 12
        // 1 : 2 : 1 — figure, ribbons, legend. Both side columns are capped: a
        // 28 pt number needs ~130 pt, and a legend row wider than ~230 pt turns
        // into a two-column table with a hole in the middle.
        let unit = max(110, (w - gap * 2) / 4)
        let sourceW = min(unit, compact ? 132 : 176)
        let rowW = min(unit, compact ? 168 : 232)
        // The ribbons span the two gaps as well, so they leave the source panel
        // and arrive at the legend rows without a blank strip in between.
        let ribbonStart = sourceW
        let ribbonEnd = max(ribbonStart + 60, w - rowW)

        // Only components with a real flow get a branch (idle ones hide, like AlDente).
        // A branch only exists if the *model* gives it power. Testing the smoothed
        // value instead kept a stale, already-zeroed branch on screen for a while
        // (it rendered as "其他 —" right after launch).
        let sinks = model.sinks.filter { ($0.watts ?? 0) >= 0.05 }
        // Clamp to the measured total: right after launch the smooth filter can
        // still be decaying from a bogus first SMC sample, which briefly printed a
        // branch larger than the whole machine.
        let ceiling = model.sourcePower > 0.05 ? model.sourcePower : .greatestFiniteMagnitude
        let values = sinks.map { min(ceiling, max(0, ticker.smoothedSinks[$0.id] ?? $0.watts ?? 0)) }
        let total = max(0.001, values.reduce(0, +))
        // Compact spacing: with 3 branches a 12 pt gap read as three separate
        // lanes instead of one bundle caused by the same source.
        let slotGap: CGFloat = compact ? 7 : 8
        let gaps = slotGap * CGFloat(max(0, sinks.count - 1))

        // Rows never stretch with their watt value, and are capped so a lone
        // branch does not become a 190 pt bar.
        let rowH: CGFloat = sinks.isEmpty ? 0
            : min(compact ? 40 : 44, (h - gaps) / CGFloat(sinks.count))
        // Centred, so 1 or 3 branches occupy the same frame.
        let rowsH = rowH * CGFloat(sinks.count) + gaps
        var rowTop = max(0, (h - rowsH) / 2)

        // Source neck: narrow on the ribbon side so the branches read as a fan
        // opening towards the legend, not parallel slabs.
        let bandH = h * (compact ? 0.19 : 0.17)
        var cursor = (h - bandH) / 2

        var placed: [Placed] = []
        for (index, sink) in sinks.enumerated() {
            let share = values[index] / total
            let startH = max(1.6, bandH * CGFloat(share))
            let startTop = cursor
            let startBottom = min(h, startTop + startH)
            cursor = startBottom + (compact ? 1.5 : 2)

            let center = rowTop + rowH / 2
            // Thin branches keep a visible body, thick ones stay inside their row.
            let thickness = max(4, min(rowH - 8, rowH * 1.18 * CGFloat(share)))

            placed.append(Placed(sink: sink,
                                 startTop: startTop, startBottom: startBottom,
                                 endTop: center - thickness / 2,
                                 endBottom: center + thickness / 2,
                                 rowTop: rowTop, rowHeight: rowH))
            rowTop += rowH + slotGap
        }

        // The figure panel hugs its three lines instead of filling the card
        // height, which is what left two thirds of it empty.
        let sourceH = min(h, compact ? 96 : 116)
        return Layout(placed: placed,
                      sourceW: sourceW, sourceH: sourceH, sourceY: (h - sourceH) / 2,
                      ribbonStart: ribbonStart, ribbonEnd: ribbonEnd, rowW: rowW)
    }

    private func curvePoint(t: Double, x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat) -> CGPoint {
        let control = max(16, (x1 - x0) * 0.46)
        let p0 = CGPoint(x: x0, y: y0)
        let p1 = CGPoint(x: x0 + control, y: y0)
        let p2 = CGPoint(x: x1 - control, y: y1)
        let p3 = CGPoint(x: x1, y: y1)
        let u = 1 - t
        let x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x
        let y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
        return CGPoint(x: x, y: y)
    }

    // MARK: body

    var body: some View {
        GeometryReader { geo in
            let layout = compute(geo.size)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    drawRibbons(context: &context, layout: layout)
                }
                .allowsHitTesting(false)

                sourceNode(layout)

                // On a machine whose SMC exposes no per-component counters the
                // branch list is empty, and without this the card was one small
                // panel in a large blank field.
                if layout.placed.isEmpty {
                    EmptyState(symbol: "chart.bar.xaxis",
                               title: t("暂无分项读数"),
                               message: t("SoC 与显示功耗由 SMC 提供；读数到达前只显示总功率。"),
                               layout: .inline)
                        .frame(width: max(0, layout.ribbonEnd - layout.ribbonStart),
                               height: geo.size.height, alignment: .leading)
                        .offset(x: layout.ribbonStart)
                }

                ForEach(Array(layout.placed.enumerated()), id: \.offset) { item in
                    sinkRow(item.element, layout: layout)
                }
            }
        }
        .onAppear { ticker.update(model); ticker.start() }
        .onDisappear { ticker.stop() }
    }

    // MARK: canvas

    private func drawRibbons(context: inout GraphicsContext, layout: Layout) {
        for item in layout.placed {
            let color = item.sink.color
            let path = ribbonPath(startX: layout.ribbonStart, endX: layout.ribbonEnd,
                                  startTop: item.startTop, startBottom: item.startBottom,
                                  endTop: item.endTop, endBottom: item.endBottom)

            // The same 11–38 % alpha that reads as a soft glow on black is a
            // barely visible smudge on white, so light mode gets more pigment.
            let lift: Double = theme.isDark ? 1.0 : 1.7
            context.fill(path, with: .linearGradient(
                Gradient(stops: [
                    .init(color: color.opacity(min(0.58, 0.38 * lift)), location: 0),
                    .init(color: color.opacity(min(0.38, 0.20 * lift)), location: 0.55),
                    .init(color: color.opacity(min(0.22, 0.11 * lift)), location: 1)
                ]),
                startPoint: CGPoint(x: layout.ribbonStart, y: 0),
                endPoint: CGPoint(x: layout.ribbonEnd, y: 0)))

            // A bright top edge + faint bottom edge reads as a glass ribbon and
            // keeps neighbouring branches from merging into one block.
            let control = max(16, (layout.ribbonEnd - layout.ribbonStart) * 0.46)
            var topEdge = Path()
            topEdge.move(to: CGPoint(x: layout.ribbonStart, y: item.startTop))
            topEdge.addCurve(to: CGPoint(x: layout.ribbonEnd, y: item.endTop),
                             control1: CGPoint(x: layout.ribbonStart + control, y: item.startTop),
                             control2: CGPoint(x: layout.ribbonEnd - control, y: item.endTop))
            var bottomEdge = Path()
            bottomEdge.move(to: CGPoint(x: layout.ribbonStart, y: item.startBottom))
            bottomEdge.addCurve(to: CGPoint(x: layout.ribbonEnd, y: item.endBottom),
                                control1: CGPoint(x: layout.ribbonStart + control, y: item.startBottom),
                                control2: CGPoint(x: layout.ribbonEnd - control, y: item.endBottom))
            context.stroke(topEdge, with: .color(color.opacity(theme.isDark ? 0.45 : 0.62)), lineWidth: 1)
            context.stroke(bottomEdge, with: .color(color.opacity(theme.isDark ? 0.14 : 0.24)), lineWidth: 0.8)

            let watts = ticker.smoothedSinks[item.sink.id] ?? item.sink.watts ?? 0
            let intensity = min(1.0, watts / 14.0)
            let count = max(2, Int(2 + intensity * 4))
            let speed = 0.30 + min(0.55, watts / 40.0)
            let centerStart = (item.startTop + item.startBottom) / 2
            let centerEnd = (item.endTop + item.endBottom) / 2
            let radius = 1.5 + 1.1 * CGFloat(intensity)

            for index in 0..<count {
                let offset = Double(index) / Double(count)
                var t = (ticker.phase * speed + offset).truncatingRemainder(dividingBy: 1)
                t = t * t * (3 - 2 * t)
                // Comet: a soft halo plus a bright core with two faded tails.
                for tail in 0..<3 {
                    let tt = max(0, t - Double(tail) * 0.018)
                    let q = curvePoint(t: tt, x0: layout.ribbonStart, x1: layout.ribbonEnd,
                                       y0: centerStart, y1: centerEnd)
                    let fade = sin(tt * Double.pi)
                    let alpha = min(1, (tail == 0 ? 0.85 : 0.24 / Double(tail)) * fade * (theme.isDark ? 1 : 1.12))
                    let r = radius * (tail == 0 ? 1 : 1.2)
                    let halo = CGRect(x: q.x - r * 2.4, y: q.y - r * 2.4,
                                      width: r * 4.8, height: r * 4.8)
                    context.fill(Path(ellipseIn: halo), with: .color(color.opacity(alpha * 0.16)))
                    let core = CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: core), with: .color(color.opacity(alpha)))
                }
            }
        }
    }

    private func ribbonPath(startX: CGFloat, endX: CGFloat,
                            startTop: CGFloat, startBottom: CGFloat,
                            endTop: CGFloat, endBottom: CGFloat) -> Path {
        var path = Path()
        let control = max(16, (endX - startX) * 0.46)
        path.move(to: CGPoint(x: startX, y: startTop))
        path.addCurve(to: CGPoint(x: endX, y: endTop),
                      control1: CGPoint(x: startX + control, y: startTop),
                      control2: CGPoint(x: endX - control, y: endTop))
        path.addLine(to: CGPoint(x: endX, y: endBottom))
        path.addCurve(to: CGPoint(x: startX, y: startBottom),
                      control1: CGPoint(x: endX - control, y: endBottom),
                      control2: CGPoint(x: startX + control, y: startBottom))
        path.closeSubpath()
        return path
    }

    // MARK: pieces

    /// The left column: the one figure this card exists to show, at `display`
    /// size, plus the system draw the ribbons are split from. It used to be a
    /// panel stretched to the full card height with three short lines centred in
    /// it, which left most of the panel empty.
    private func sourceNode(_ layout: Layout) -> some View {
        let isAdapter = model.source == .adapter
        let tint = isAdapter ? theme.flowAdapter : theme.flowBattery
        let watts = ticker.shownSource > 0 ? ticker.shownSource : ticker.smoothedSource
        let system = ticker.shownSystem > 0 ? ticker.shownSystem : ticker.smoothedSystem
        let pulse = 0.62 + 0.38 * (0.5 + 0.5 * sin(ticker.phase * .pi * 2))

        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: isAdapter ? "powerplug.fill" : "battery.75")
                    .font(Glyph.row)
                    .foregroundColor(tint)
                    .opacity(isAdapter ? pulse : 1)
                Text(isAdapter ? t("电源适配器") : t("电池供电"))
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)
            }
            Text(PowerFormat.watts(watts))
                .font(Typography.display)
                .foregroundColor(theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .numericTextTransition()
            Text(tf("系统 {p}", PowerFormat.watts(system)))
                .font(Typography.micro)
                .foregroundColor(theme.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, Spacing.m)
        .frame(width: layout.sourceW, height: layout.sourceH, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(theme.isDark ? Color.white.opacity(0.045) : Color.black.opacity(0.022))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1)
        )
        .offset(y: layout.sourceY)
        .help(isAdapter ? t("电源适配器输入功率") : t("电池输出功率"))
    }

    /// The right column: one row per branch, icon + name + watts. The number sits
    /// where its ribbon arrives, so the diagram no longer needs labels floating
    /// over the curves.
    private func sinkRow(_ item: Placed, layout: Layout) -> some View {
        let active = (ticker.smoothedSinks[item.sink.id] ?? item.sink.watts ?? 0) > 0.02
        // Fall back to the live value when the throttled snapshot still holds 0
        // for a branch that just appeared; otherwise it prints "—" for a second.
        let shown = ticker.shownSinks[item.sink.id] ?? 0
        let watts = shown > 0.05 ? shown : (item.sink.watts ?? 0)

        return HStack(spacing: Spacing.s) {
            Image(systemName: item.sink.symbol)
                .font(Glyph.row)
                .foregroundColor(item.sink.color)
                .opacity(active ? 1 : 0.5)
            Text(item.sink.title)
                .font(Typography.label)
                .foregroundColor(active ? theme.textSecondary : theme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: Spacing.xs)
            Text(PowerFormat.watts(watts))
                .font(Typography.label.monospacedDigit())
                .foregroundColor(active ? theme.textPrimary : theme.textTertiary)
                .lineLimit(1)
                .numericTextTransition()
        }
        .padding(.horizontal, Spacing.m)
        .frame(width: layout.rowW, height: item.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(item.sink.color.opacity(active ? 0.13 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(item.sink.color.opacity(active ? 0.30 : 0.14), lineWidth: 1)
        )
        .offset(x: layout.ribbonEnd, y: item.rowTop)
        .help([item.sink.title + (item.sink.quality == .estimated ? t("（估算）") : ""), item.sink.detail]
            .compactMap { $0 }.joined(separator: " · "))
    }
}