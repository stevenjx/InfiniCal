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
struct EmptyState: View {
    /// `stacked` centres the block inside a card; `inline` lays it out as a row,
    /// for cards whose height is set by a sibling rather than by the message.
    enum Layout { case stacked, inline }

    private var theme: Theme { Theme.current }

    let symbol: String
    let title: String
    var message: String? = nil
    var layout: Layout = .stacked
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        switch layout {
        case .stacked: stacked
        case .inline: inline
        }
    }

    private var stacked: some View {
        VStack(spacing: Spacing.s + Spacing.xxs) {
            Image(systemName: symbol)
                .font(Glyph.hero)
                .foregroundColor(theme.textTertiary)
            Text(title)
                .font(Typography.headline)
                .foregroundColor(theme.textPrimary)
            if let message {
                Text(message)
                    .font(Typography.caption)
                    .foregroundColor(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(Typography.caption)
                    .padding(.top, Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.l)
    }

    private var inline: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: symbol)
                .font(Glyph.block)
                .foregroundColor(theme.textTertiary)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(Typography.headline)
                    .foregroundColor(theme.textPrimary)
                if let message {
                    Text(message)
                        .font(Typography.caption)
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
