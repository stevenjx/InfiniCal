import SwiftUI

struct FirstRunHelperSheet: View {
    @EnvironmentObject private var state: AppState
    private var theme: Theme { Theme.current }

    var body: some View {
        SheetScaffold(title: t(HelperClient.shared.needsUpdate ? "更新特权助手" : "安装特权助手"),
                      symbol: "lock.shield.fill",
                      width: 400) {
            Text(t("InfiniCal 需要特权助手才能精确读取 SMC 数据，并执行充电限制、放电和电池校准。助手只用于本机电池控制，不联网。"))
                .font(Typography.body)
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            SheetFooter(cancelTitle: t("稍后安装"),
                        onCancel: { state.dismissFirstRunHelperPrompt() },
                        confirmTitle: t("安装特权助手"),
                        onConfirm: {
                            // Close the sheet first: the system authorization
                            // dialog is modal, and overlapping it with the sheet
                            // transition leaves SwiftUI's gesture recognizers
                            // stuck (AppKit logs a "Stuck gesture recognizers"
                            // warning).
                            state.dismissFirstRunHelperPrompt()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                state.installHelper()
                            }
                        })
        }
    }
}
