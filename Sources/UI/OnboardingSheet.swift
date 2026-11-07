//
//  OnboardingSheet.swift
//  First launch: the three things the app cannot do for the user.
//
//  Why a sheet and not a banner: each of these needs an explicit decision, and
//  two of them open a system dialog. A banner that scrolls away mid-decision is
//  how the old helper prompt ended up being dismissed without being read.
//
//  Order is deliberate. The helper comes first because half the app is dead
//  without it, and the two switches come after, so the user sees exactly what
//  they are enabling rather than clicking through a wall of agreements.
//

import SwiftUI

struct OnboardingSheet: View {

    @EnvironmentObject private var state: AppState
    /// Local until 完成 is pressed: the onboarding must not silently flip system
    /// settings the moment it appears.
    @State private var enableAutoUpdate = true
    @State private var enableLaunchAtLogin = true
    private var theme: Theme { Theme.current }
    @ObservedObject private var updater = SparkleUpdater.shared

    private var helperReady: Bool { state.helperInstalled && !HelperClient.shared.needsUpdate }

    var body: some View {
        SheetScaffold(title: t("开始使用 InfiniCal"),
                      symbol: "sparkles",
                      width: 460) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(t("这台 Mac 上的电池数据全部在本地读取与保存。下面三项只影响本机行为，随时可以在设置里改。"))
                    .font(Typography.body)
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                helperStep
                updateStep
                loginStep
            }
        } footer: {
            SheetFooter(cancelTitle: t("稍后再说"),
                        onCancel: {
                            state.completeOnboarding()
                        },
                        confirmTitle: t("完成"),
                        onConfirm: finish)
        }
    }

    // MARK: - Steps

    /// The one step that is not optional for most of the app, so it is styled
    /// differently and reports its own progress and failure inline.
    private var helperStep: some View {
        step(symbol: "lock.shield.fill",
             title: t("安装特权助手"),
             detail: t("充电上限、放电、风扇与校准都要写 SMC，这需要一次系统授权。助手只在本机运行，不联网。"),
             tint: theme.accent) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                switch state.helperInstallPhase {
                case .installing:
                    HStack(spacing: Spacing.s) {
                        ProgressView().controlSize(.small)
                        Text(t("正在请求授权…请在系统弹窗中允许"))
                            .font(Typography.caption)
                            .foregroundColor(theme.textSecondary)
                    }
                case .failed(let message):
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(message)
                            .font(Typography.caption)
                            .foregroundColor(theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: Spacing.s) {
                            SmallActionButton(title: t("重试"), symbol: "arrow.clockwise") {
                                state.installHelper()
                            }
                            Spacer(minLength: 0)
                        }
                        Text(t("如果反复失败：打开「系统设置 → 隐私与安全性」，确认已允许 InfiniCal 安装辅助工具后重试。"))
                            .font(Typography.micro)
                            .foregroundColor(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .idle:
                    HStack(spacing: Spacing.s) {
                        if helperReady {
                            Label(t("已安装"), systemImage: "checkmark.circle.fill")
                                .font(Typography.caption)
                                .foregroundColor(theme.success)
                        } else {
                            SmallActionButton(title: HelperClient.shared.needsUpdate ? t("更新助手") : t("安装助手"),
                                              symbol: "lock.shield") {
                                state.installHelper()
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                Text(helperReady
                     ? t("没有助手的机器上，只有读取类功能可用：仪表板、历史、睡眠报告仍然工作。")
                     : t("跳过安装也可以先用：读数与历史不需要助手，写入类功能会保持禁用。"))
                    .font(Typography.micro)
                    .foregroundColor(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var updateStep: some View {
        step(symbol: "arrow.triangle.2.circlepath",
             title: t("自动检查更新"),
             detail: t("每天检查一次 GitHub Releases，签名校验通过后才会提示。默认关闭，由你决定是否开启。"),
             tint: theme.chartBlue) {
            Toggle(isOn: $enableAutoUpdate) {
                Text(t("自动检查更新"))
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var loginStep: some View {
        step(symbol: "power",
             title: t("登录时启动"),
             detail: t("让充电上限在登录后就生效，而不是等你打开窗口。（关闭 Dock 图标后，菜单栏是唯一入口，这一项更有用。）"),
             tint: theme.chartPurple) {
            Toggle(isOn: $enableLaunchAtLogin) {
                Text(t("登录时启动"))
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: - Layout

    private func step<Control: View>(symbol: String, title: String,
                                     detail: String, tint: Color,
                                     @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            ZStack {
                Circle().fill(tint.opacity(theme.isDark ? 0.18 : 0.12)).frame(width: 30, height: 30)
                Image(systemName: symbol)
                    .font(Glyph.row)
                    .foregroundColor(tint)
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title).font(Typography.headline).foregroundColor(theme.textPrimary)
                Text(detail)
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                control()
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(theme.card))
    }

    // MARK: - Finish

    private func finish() {
        if enableAutoUpdate != updater.automaticallyChecks {
            updater.automaticallyChecks = enableAutoUpdate
        }
        if enableLaunchAtLogin != state.launchAtLogin {
            state.launchAtLogin = enableLaunchAtLogin
        }
        state.completeOnboarding()
    }
}