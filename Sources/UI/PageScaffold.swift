//
//  PageScaffold.swift
//  The frame and the empty state every panel shares (U0-04).
//

import SwiftUI

/// The frame every panel shares.
///
/// Before this, each of the eight panels decided three things on its own: where
/// the title went (three of them had none at all), what inset the content used
/// (18 / 20 / 22), and whether the title scrolled away with the content. Moving
/// between panels therefore shifted the title by up to 4 pt sideways, and on
/// the dashboard and settings pages there was no title to land on.
///
/// The header sits outside the `ScrollView` on purpose: the panel name and its
/// actions stay put while the content scrolls under them.
struct PageScaffold<Content: View, Toolbar: View>: View {
    private var theme: Theme { Theme.current }

    let title: String
    var symbol: String? = nil
    var help: String? = nil
    @ViewBuilder var toolbar: Toolbar
    @ViewBuilder var content: Content

    /// 20 pt: the horizontal inset for the header and for the content. One
    /// value for all eight panels, per §2.2 of the plan.
    private static var horizontal: CGFloat { Spacing.xl }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.s) {
                if let symbol { IconBadge(symbol: symbol) }
                Text(title)
                    .font(Typography.title)
                    .foregroundColor(theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                if let help { HelpDot(text: help) }
                Spacer(minLength: Spacing.m)
                toolbar
            }
            .frame(height: 34)
            .padding(.horizontal, Self.horizontal)
            .padding(.top, Spacing.m)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Self.horizontal)
                .padding(.top, Spacing.m)
                .padding(.bottom, Spacing.l)
            }
        }
    }
}

extension PageScaffold where Toolbar == EmptyView {
    init(title: String, symbol: String? = nil, help: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, help: help,
                  toolbar: { EmptyView() }, content: content)
    }
}

/// The one empty state in the app.
///
/// The history page drew a centred icon-title-message block, the fan page drew
/// the same three pieces as a row, and the schedule page printed a bare grey
/// sentence inside the list. All three are the same message: "there is nothing
/// here yet, and this is what would put something here".
///
/// Three tones, because "nothing here yet" and "we could not read it" are not
/// the same thing and used to look identical:
///
/// - `neutral` — no data yet. Grey icon; nothing is wrong.
/// - `loading` — a read is in flight. Spinner in place of the icon.
/// - `failure` — the read failed. Danger icon and, above all, a **reason**.
///   A failure that says only "失败" tells the user nothing they can act on,
///   so `reason` is what distinguishes this tone from a plain empty state.
///
/// `Actions` is a view slot rather than a title/closure pair because the
/// schedule page's empty state needs two actions and one of them is a menu
/// (模板). The pair that used to sit here had no callers and could not express
/// that, and a title-only button cannot be styled as the primary action.
struct EmptyState<Actions: View>: View {
    /// `stacked` centres the block inside a card; `inline` lays it out as a row,
    /// for cards whose height is set by a sibling rather than by the message.
    enum Layout { case stacked, inline }

    enum Tone {
        case neutral
        case loading
        case failure
    }

    private var theme: Theme { Theme.current }

    let symbol: String
    let title: String
    var message: String? = nil
    var layout: Layout = .stacked
    var tone: Tone = .neutral
    @ViewBuilder var actions: Actions

    private var tint: Color {
        switch tone {
        case .neutral: return theme.textTertiary
        case .loading: return theme.textSecondary
        case .failure: return theme.danger
        }
    }

    var body: some View {
        switch layout {
        case .stacked: stacked
        case .inline: inline
        }
    }

    private var stacked: some View {
        VStack(spacing: Spacing.s + Spacing.xxs) {
            glyph(font: Glyph.hero, height: 30)
            Text(title)
                .font(Typography.headline)
                .foregroundColor(theme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            if let message {
                Text(message)
                    .font(Typography.caption)
                    .foregroundColor(tone == .failure ? theme.textPrimary : theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }
            // No padding of its own: an empty slot must not add height to the
            // three pages that pass no actions.
            actions
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.l)
    }

    private var inline: some View {
        HStack(spacing: Spacing.s) {
            glyph(font: Glyph.block, height: 18)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(Typography.headline)
                    .foregroundColor(theme.textPrimary)
                if let message {
                    Text(message)
                        .font(Typography.caption)
                        .foregroundColor(tone == .failure ? theme.textPrimary : theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func glyph(font: Font, height: CGFloat) -> some View {
        if tone == .loading {
            // A spinner has no intrinsic size comparable to a glyph, so the row
            // height is pinned to what the icon would have taken. Approximate
            // on purpose — a spinner that changes row height on appear is worse
            // than one a point or two off centre.
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
                .frame(height: height)
        } else {
            Image(systemName: symbol)
                .font(font)
                .foregroundColor(tint)
        }
    }
}

extension EmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String? = nil,
         layout: Layout = .stacked, tone: Tone = .neutral) {
        self.init(symbol: symbol, title: title, message: message,
                  layout: layout, tone: tone) { EmptyView() }
    }
}

/// Failure state with one recovery button — the shape every "we could not
/// read X" in the app should have.
///
/// `reason` is required on purpose. A failure that says only "失败" is exactly
/// what this tone exists to prevent, so there is no initialiser that lets you
/// omit it. The button takes its own title because the recovery is sometimes
/// "重试" and sometimes "安装" (a write failed because the privileged helper is
/// missing — retrying will not help).
struct RetryState: View {
    private var theme: Theme { Theme.current }

    let symbol: String
    let title: String
    /// Why it failed. Never "失败" on its own.
    let reason: String
    var layout: EmptyState<EmptyView>.Layout = .stacked
    /// Button text. Defaults to 重试; pass 安装 when the fix is installing.
    var actionTitle: String? = nil
    let retry: () -> Void

    var body: some View {
        switch layout {
        case .stacked:
            VStack(spacing: Spacing.m) {
                RetryStateContent(symbol: symbol, title: title, reason: reason,
                                  layout: .stacked)
                actionButton
            }
        case .inline:
            // Inline rows set their own height from a sibling, so stacking the
            // button underneath would stretch the row. `EmptyState.inline`
            // already ends in a Spacer, so the button lands at the right edge.
            HStack(spacing: Spacing.s) {
                RetryStateContent(symbol: symbol, title: title, reason: reason,
                                  layout: .inline)
                actionButton
            }
        }
    }

    private var actionButton: some View {
        Button(action: retry) {
            Text(actionTitle ?? t("重试"))
                .font(Typography.label)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(theme.accent))
                .foregroundColor(.white)
        }
        .buttonStyle(.plain)
    }
}

/// The icon/title/reason half of `RetryState`, split so the button can sit at
/// a fixed distance below it in both layouts.
private struct RetryStateContent: View {
    let symbol: String
    let title: String
    let reason: String
    let layout: EmptyState<EmptyView>.Layout

    var body: some View {
        EmptyState(symbol: symbol, title: title, message: reason, layout: layout, tone: .failure)
    }
}

// MARK: - Sheets

/// The frame every modal shares.
///
/// Six surfaces — 校准方式、校准历史、硬件诊断、软件更新、新建任务、特权助手 ——
/// each picked its own title size (13 in four, 15 in one, the bare `.headline`
/// in another), its own inset (14 / 20 / 24) and put its buttons wherever the
/// author happened to be standing: in the header row, at the end of a trailing
/// HStack, or centred under the text. Two of them answered Esc; the rest did
/// not.
///
/// One skeleton now: header (symbol + title 15 + explanation 11), a footer bar,
/// and a body in between that may scroll. The footer sits outside the body, so
/// a long record list scrolls under a bar that does not move.
///
/// The corner radius is not set here. On macOS a `.sheet` is an AppKit sheet
/// window and AppKit draws its corners; a rounded rectangle of our own inside it
/// would be a second, slightly different curve.
struct SheetScaffold<Content: View, Footer: View>: View {
    private var theme: Theme { Theme.current }

    let title: String
    var symbol: String? = nil
    var subtitle: String? = nil
    var width: CGFloat = 420
    /// `nil` lets the sheet hug its content. A number pins it — the record list
    /// and the diagnostics sheet would otherwise resize as rows arrive.
    var height: CGFloat? = nil
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    /// 20 pt, the same inset the panels use, per §2.2 of the plan.
    private static var inset: CGFloat { Spacing.xl }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.divider)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, Self.inset)
                .padding(.vertical, Spacing.l)
            Divider().background(theme.divider)
            footer
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, Self.inset)
                .padding(.vertical, Spacing.m + Spacing.xxs)
        }
        .frame(width: width)
        .frame(height: height)
        .background(theme.windowBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                if let symbol { IconBadge(symbol: symbol, color: theme.accent) }
                Text(title)
                    .font(Typography.title)
                    .foregroundColor(theme.textPrimary)
            }
            if let subtitle {
                Text(subtitle)
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Self.inset)
        .padding(.top, Self.inset)
        .padding(.bottom, Spacing.m)
    }
}

/// The button bar: optional secondary actions on the left, then the pair that
/// ends the sheet on the right.
///
/// The buttons are the system's rather than a capsule of our own. A filled
/// accent capsule would carry white 12 pt text at 3.6:1 (measured on this
/// palette), and this is the one place in the app where a button is the last
/// step before a hardware change — the platform control is both readable and
/// what a Mac user expects in a sheet. `.defaultAction` / `.cancelAction` also
/// give Return and Esc without a second mechanism.
struct SheetFooter<Leading: View>: View {
    var cancelTitle: String? = nil
    var onCancel: (() -> Void)? = nil
    var confirmTitle: String? = nil
    var onConfirm: (() -> Void)? = nil
    /// For a sheet whose only button is 关闭 or 完成: it is the default action,
    /// but Esc has to reach it too, and a button carries one shortcut.
    var confirmAnswersEscape = false
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(spacing: Spacing.m) {
            leading
            Spacer(minLength: Spacing.m)
            if let cancelTitle, let onCancel {
                Button(cancelTitle, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            if let confirmTitle, let onConfirm {
                Button(confirmTitle, action: onConfirm)
                    .keyboardShortcut(confirmAnswersEscape ? .cancelAction : .defaultAction)
            }
        }
    }
}

extension SheetFooter where Leading == EmptyView {
    init(cancelTitle: String? = nil, onCancel: (() -> Void)? = nil,
         confirmTitle: String? = nil, onConfirm: (() -> Void)? = nil,
         confirmAnswersEscape: Bool = false) {
        self.init(cancelTitle: cancelTitle, onCancel: onCancel,
                  confirmTitle: confirmTitle, onConfirm: onConfirm,
                  confirmAnswersEscape: confirmAnswersEscape) { EmptyView() }
    }
}
