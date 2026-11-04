//
//  DeviceProfileCard.swift
//  The cross-model capability profile shown inside the diagnostics sheet.
//

import SwiftUI
import AppKit

struct DeviceProfileCard: View {

    let assessment: CapabilityAssessment
    /// Called after the rule library changes, so the parent can re-capture the
    /// profile and re-run the assessment.
    var onLibraryChanged: () -> Void

    @ObservedObject private var store = DeviceProfileStore.shared
    @StateObject private var error = UIValue<String?>(nil)

    private var theme: Theme { Theme.current }

    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                header
                Text(assessment.profile.summary)
                    .font(Typography.headline)
                    .foregroundColor(theme.textPrimary)
                    .textSelection(.enabled)
                chips
                block(t("本机实测"), assessment.notes, theme.textSecondary)
                block(t("已知限制"), assessment.limitations, theme.chartOrange)
                block(t("推荐策略"), assessment.recommendations, theme.textPrimary)
                Text(t("规则离线内置，不上传任何数据；画像只包含机型代码、芯片名称与系统版本。"))
                    .font(Typography.caption)
                    .foregroundColor(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = store.message {
                    Text(message).font(Typography.caption).foregroundColor(theme.chartGreen)
                }
                if let error = error.value {
                    Text(error).font(Typography.caption).foregroundColor(theme.chartOrange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(t("跨机型能力画像")).font(Typography.headline)
            Text(tf("规则库 v{p}", "\(assessment.libraryVersion)"))
                .font(Typography.caption.monospaced())
                .foregroundColor(theme.textTertiary)
            Text(tf("命中 {p} 条", "\(assessment.ruleIDs.count)"))
                .font(Typography.caption)
                .foregroundColor(theme.textTertiary)
            Spacer()
            Button(t("导入规则…")) { importRules() }
                .font(Typography.caption)
            Button(t("回滚")) { rollBack() }
                .font(Typography.caption)
                .disabled(!store.canRollBack)
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            chip(t("后端"), assessment.profile.backendTitle)
            chip(t("助手"), assessment.profile.helperAvailable ? t("已连接") : t("未连接"))
            chip(t("风扇"), "\(assessment.profile.fanCount)")
            chip(t("传感器"), "\(assessment.profile.sensorKeys.count)")
            Spacer(minLength: 0)
        }
    }

    private func chip(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundColor(theme.textTertiary)
            Text(value).foregroundColor(theme.textSecondary)
        }
        .font(Typography.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.innerControl))
    }

    @ViewBuilder
    private func block(_ title: String, _ items: [String], _ color: Color) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.micro.weight(.semibold)).foregroundColor(theme.textTertiary)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 4) {
                        Text("·").font(Typography.caption).foregroundColor(color)
                        Text(t(item)).font(Typography.caption).foregroundColor(color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func importRules() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["json"]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.install(from: url)
            error.value = nil
            onLibraryChanged()
        } catch {
            self.error.value = error.localizedDescription
        }
    }

    private func rollBack() {
        do {
            try store.rollback()
            error.value = nil
            onLibraryChanged()
        } catch {
            self.error.value = error.localizedDescription
        }
    }
}
