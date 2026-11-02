import SwiftUI
import AppKit

private final class UpdatePanelActions: ObservableObject {
    @Published var error: String?
}

/// 可直接嵌入设置；菜单栏 sheet 使用 UpdateSheet。
@MainActor
struct UpdatePanel: View {
    @ObservedObject private var checker = UpdateChecker.shared
    @ObservedObject private var calibration = CalibrationEngine.shared
    @ObservedObject private var app = AppState.shared
    @StateObject private var actions = UpdatePanelActions()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("软件更新")).font(.headline)
            Text(tf("当前版本：{p}", checker.currentVersion.isEmpty ? t("未知") : checker.currentVersion))

            HStack {
                Button(t("检查更新")) {
                    actions.error = nil
                    checker.check()
                }
                .disabled(checker.status == .checking)
                if checker.status == .checking { ProgressView().controlSize(.small) }
            }
            Text(statusText).fixedSize(horizontal: false, vertical: true)
            if let code = checker.networkFailureCode {
                Text("NSURLErrorDomain · \(code)").font(.caption).textSelection(.enabled)
            }
            Button(t("在浏览器中查看最新发布")) {
                if let url = URL(string: "https://github.com/stevenjx/InfiniCal/releases/latest") { open(url) }
            }
            if let lastAttempt = checker.lastAttempt {
                Text(tf("上次尝试：{p}", lastAttempt.formatted(date: .numeric, time: .shortened)))
                    .font(.caption).foregroundColor(.secondary)
            }

            if let release = checker.release {
                Divider()
                Text(tf("可用版本：{p}", release.tag)).font(.headline)
                Text(t("发布日志（原文）"))
                ScrollView {
                    Text(verbatim: release.notes.isEmpty ? t("此版本未提供发布日志。") : release.notes)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 100, idealHeight: 180, maxHeight: 240)
                HStack {
                    if let url = release.downloadURL {
                        Button(t("下载更新")) { open(url) }
                    }
                    Button(t("查看官方发布页")) { open(release.pageURL) }
                    Button(t("跳过此版本")) { checker.skip() }
                }
                Text(t("下载仅在浏览器中打开官方 DMG 链接，不会退出应用或替换文件。"))
                    .font(.caption).foregroundColor(.secondary)
            }

            Divider()
            if calibration.isRunning {
                Text(t("校准正在运行：下载不受影响；安装前请先结束校准并完成安全清理。"))
                    .foregroundColor(.orange)
            }
            if calibration.needsRecovery {
                Text(t("存在待恢复的校准记录：请先在电池校准中完成恢复或安全清理，再安装更新。"))
                    .foregroundColor(.orange)
            }
            Button(t("安全退出以安装更新")) {
                actions.error = nil
                if let error = AppState.shared.prepareForUpdate() {
                    actions.error = error
                } else {
                    NSApp.terminate(nil)
                }
            }
            Text(t("此操作仅在安全准备成功后退出；安装需由你手动完成。"))
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

    private func open(_ url: URL) {
        actions.error = NSWorkspace.shared.open(url) ? nil : t("无法打开浏览器，请稍后重试。")
    }

    private var statusText: String {
        switch checker.status {
        case .idle: return t("尚未检查更新。")
        case .checking: return t("正在检查更新…")
        case .upToDate: return t("当前已是最新稳定版本。")
        case .available: return t("发现新的稳定版本。")
        case .skipped: return t("已跳过此版本；手动检查仍可查看。")
        case .noPackage: return t("发现新版本，但没有可用的官方 DMG 安装包。")
        case .rateLimited: return t("GitHub 请求受限，请稍后重试。")
        case .notPublished: return t("官方仓库尚无可用的稳定发布。")
        case .invalidRelease: return t("发布信息校验失败：仅接受官方仓库的稳定版本与安全链接。")
        case .invalidCurrentVersion: return t("当前应用版本格式无效，无法比较更新。")
        case .networkError: return t(UpdateChecker.networkFailureKey(checker.networkFailureCode ?? 0))
        case .serviceError(let code): return tf("更新服务返回错误（HTTP {p}）。", String(code))
        }
    }
}

/// 设置与菜单栏均可 .sheet(isPresented:) { UpdateSheet() }；稍后不记录跳过。
@MainActor
struct UpdateSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            ScrollView { UpdatePanel().padding(20) }
            HStack {
                Spacer()
                Button(t("稍后")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 560, height: 620)
    }
}
