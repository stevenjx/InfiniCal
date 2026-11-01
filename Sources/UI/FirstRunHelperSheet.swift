import SwiftUI

struct FirstRunHelperSheet: View {
    @EnvironmentObject private var state: AppState
    private var theme: Theme { Theme.current }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 34))
                .foregroundColor(theme.accent)
            Text(t(HelperClient.shared.needsUpdate ? "更新特权助手" : "安装特权助手"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.textPrimary)
            Text(t("InfiniCal 需要特权助手才能精确读取 SMC 数据，并执行充电限制、放电和电池校准。助手只用于本机电池控制，不联网。"))
                .font(.system(size: 12))
                .foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(t("稍后安装")) {
                    state.dismissFirstRunHelperPrompt()
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.textSecondary)
                Button(t("安装特权助手")) {
                    // Close the sheet first: the system authorization dialog is
                    // modal, and overlapping it with the sheet transition leaves
                    // SwiftUI's gesture recognizers stuck (AppKit logs a
                    // "Stuck gesture recognizers" warning).
                    state.dismissFirstRunHelperPrompt()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        state.installHelper()
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(theme.accent))
                .foregroundColor(.white)
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(theme.windowBackground)
    }
}
