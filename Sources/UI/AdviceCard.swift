//
//  AdviceCard.swift
//  "Local advice" card shown at the top of the history panel.
//

import SwiftUI

struct AdviceCard: View {

    let report: AdviceReport

    private var theme: Theme { Theme.current }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(title: t("本地建议"),
                           help: t("只根据本机历史数据生成，每条建议都附带证据。它是使用建议，不是硬件故障诊断。")) {
                    Text(tf("已记录 {p} 天 · 有效校准 {p} 次",
                            "\(report.observedDays)", "\(report.eligibleSessions)"))
                        .font(Typography.caption)
                        .foregroundColor(theme.textTertiary)
                }
                if report.items.isEmpty {
                    Text(tf("近 {p} 天没有足够数据给出建议。继续使用后会基于温度和充电记录生成。",
                            "\(report.windowDays)"))
                        .font(Typography.caption)
                        .foregroundColor(theme.textSecondary)
                } else {
                    ForEach(report.items) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(item.level == .attention ? theme.chartOrange : theme.chartBlue)
                                    .frame(width: 5, height: 5)
                                Text(t(item.title)).font(Typography.headline)
                                    .foregroundColor(theme.textPrimary)
                                Spacer(minLength: 0)
                            }
                            Text(t(item.advice))
                                .font(Typography.caption)
                                .foregroundColor(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(Array(item.evidence.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .top, spacing: 4) {
                                    Text("·").font(Typography.caption).foregroundColor(theme.textTertiary)
                                    Text(t(line))
                                        .font(Typography.caption)
                                        .foregroundColor(theme.textTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                Text(t("建议只使用本机数据，不联网、不上传。"))
                    .font(Typography.caption)
                    .foregroundColor(theme.textTertiary)
            }
        }
    }
}
