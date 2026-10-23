//
//  PopoverView.swift
//  The menu bar popover.
//

import SwiftUI

struct PopoverView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var flowTicker = AppState.shared.flowTicker
    private var theme: Theme { Theme.current }
    var openWindow: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            header
            batteryBar
            explanation
            PowerFlowView(model: state.flowModel, ticker: flowTicker, compact: true)
                .frame(height: 156)
                .padding(.horizontal, 2)
            stats
            footer
        }
        .padding(14)
        .frame(width: 420)
        .background(theme.windowBackground)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("限制: \(state.chargeVal)%")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(theme.innerControl))
            Spacer()
            Button {
                state.topUp()
            } label: {
                HStack(spacing: 5) {
                    Text("充满").font(.system(size: 12, weight: .medium))
                    Image(systemName: "plus.circle").font(.system(size: 12))
                }
                .foregroundColor(theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(theme.innerControl))
            }
            .buttonStyle(.plain)

            Button(action: openWindow) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12))
                    .foregroundColor(theme.textPrimary)
                    .frame(width: 28, height: 26)
                    .background(Circle().fill(theme.innerControl))
            }
            .buttonStyle(.plain)
        }
    }

    private var batteryBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = CGFloat(state.snapshot.percentage) / 100
            let limitX = width * CGFloat(state.chargeVal) / 100
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(theme.innerControl)
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.42, blue: 0.85),
                                                  Color(red: 0.16, green: 0.48, blue: 0.92)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(44, width * fraction))
                    .overlay(
                        HStack {
                            Text("\(state.snapshot.percentage)%")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.leading, 10)
                            Spacer()
                            Image(systemName: state.chargeState == .charging ? "bolt.fill" : "pause.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white.opacity(0.9))
                            if state.sailingMode {
                                Image(systemName: "sailboat.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.white.opacity(0.9))
                            }
                            Spacer()
                        }
                    )
                if state.chargeVal < 100 {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.55))
                        .frame(width: 2, height: 22)
                        .offset(x: limitX - 1)
                }
            }
        }
        .frame(height: 30)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("怎么回事?")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Image(systemName: "moon.fill").font(.system(size: 9)).foregroundColor(theme.textSecondary)
                Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundColor(theme.textSecondary)
                Image(systemName: "battery.100").font(.system(size: 9)).foregroundColor(theme.textSecondary)
            }
            Text(state.stateExplanation)
                .font(.system(size: 11))
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.card)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.cardStroke, lineWidth: 1))
        )
    }

    private var stats: some View {
        VStack(spacing: 0) {
            statRow("arrow.triangle.2.circlepath", "循环次数:", "\(state.snapshot.cycleCount)")
            Divider().background(theme.divider)
            statRow("thermometer", "电池温度:", String(format: "%.0f°C", state.snapshot.temperature))
            Divider().background(theme.divider)
            statRow("clock", "充满时间:", state.snapshot.timeToFull.map { "\($0 / 60) 小时 \($0 % 60) 分" } ?? "--")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.card)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.cardStroke, lineWidth: 1))
        )
    }

    private func statRow(_ symbol: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundColor(theme.textSecondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(theme.textPrimary)
        }
        .frame(height: 28)
    }

    private var footer: some View {
        HStack {
            circle("power") { NSApp.terminate(nil) }
            Spacer()
            circle("questionmark") {
                NSWorkspace.shared.open(URL(string: "https://apphousekitchen.com")!)
            }
            circle("gearshape") { openWindow() }
        }
        .padding(.horizontal, 4)
    }

    private func circle(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(theme.innerControl))
        }
        .buttonStyle(.plain)
    }
}
