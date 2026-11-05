import SwiftUI
import AppKit

private final class UpdatePanelActions: ObservableObject {
    @Published var error: String?
}

/// 可直接嵌入设置；菜单栏 sheet 使用 UpdateSheet。
///
/// 检查、下载、签名校验、替换与重启全部交给 Sparkle。这里只负责三件事：
/// 显示当前版本、把「检查更新」交给 Sparkle 的标准窗口、以及在安装前说清
/// 楚硬件状态会被交接。
@MainActor
struct UpdatePanel: View {
    @ObservedObject private var updater = SparkleUpdater.shared
    @ObservedObject private var calibration = CalibrationEngine.shared
    @ObservedObject private var app = AppState.shared
    @StateObject private var actions = UpdatePanelActions()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tf("当前版本：{p}", updater.currentVersion.isEmpty ? t("未知") : updater.currentVersion))

            HStack {
                Button(t("检查更新")) {
                    actions.error = nil
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
                if !updater.canCheckForUpdates { ProgressView().controlSize(.small) }
            }
            Text(statusText).fixedSize(horizontal: false, vertical: true)

            ToggleRow(symbol: "clock.arrow.circlepath",
                      title: t("自动检查更新"),
                      help: t("Sparkle 会按系统节奏在后台查询 appcast；发现新版本时提示你确认后才会下载。"),
                      isOn: $updater.automaticallyChecks)

            if let version = updater.availableVersion {
                Divider()
                Text(tf("可用版本：{p}", version)).font(.headline)
                Text(t("下载与安装由 Sparkle 完成：它会校验更新包的 EdDSA 签名，替换应用后自动重启。"))
                    .font(.caption).foregroundColor(.secondary)
            }

            if let lastCheck = updater.lastCheckDate {
                Text(tf("上次检查：{p}", lastCheck.formatted(date: .numeric, time: .shortened)))
                    .font(.caption).foregroundColor(.secondary)
            }
            if let error = updater.lastError {
                Text(verbatim: error)
                    .font(.caption).foregroundColor(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            if calibration.isRunning {
                Text(t("校准正在运行：此时不会下载或安装更新，请先结束校准。"))
                    .foregroundColor(.orange)
            }
            if calibration.needsRecovery {
                Text(t("存在待恢复的校准记录：请先在电池校准中完成恢复或安全清理，再安装更新。"))
                    .foregroundColor(.orange)
            }
            Text(t("安装前会自动恢复风扇与充电控制并取消睡眠断言；校准进行中则拒绝更新。"))
                .font(.caption).foregroundColor(.secondary)

            if app.updatePreparationActive {
                Text(t("自动控制已暂停；可重试安全退出，或取消准备并安全恢复。恢复失败将保持暂停。"))
                    .font(.caption).foregroundColor(.orange)
                Button(t("取消更新准备并安全恢复")) {
                    actions.error = app.cancelUpdatePreparation()
                }
            }
            Text(t("取消准备成功后，风扇恢复系统自动，曲线关闭；如需固定转速、全速或曲线，请之后手动重选。"))
                .font(.caption).foregroundColor(.secondary)
            if let error = actions.error {
                Text(verbatim: error)
                    .foregroundColor(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusText: String {
        if let version = updater.availableVersion {
            return tf("发现新版本 {p}。", version)
        }
        guard let last = updater.lastCheckDate else { return t("尚未检查更新。") }
        return tf("当前已是最新稳定版本（{p} 检查）。", last.formatted(date: .numeric, time: .shortened))
    }
}

/// 菜单栏与设置页均 `.sheet(isPresented:) { UpdateSheet() }`。标题由
/// `SheetScaffold` 提供，面板本身不带页头，换到别处嵌入时由宿主决定。
@MainActor
struct UpdateSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(title: t("软件更新"),
                      symbol: "arrow.triangle.2.circlepath",
                      width: 560) {
            ScrollView { UpdatePanel() }
        } footer: {
            SheetFooter(confirmTitle: t("关闭"),
                        onConfirm: { dismiss() },
                        confirmAnswersEscape: true)
        }
    }
}
