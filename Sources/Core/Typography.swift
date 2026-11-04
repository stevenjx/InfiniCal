//
//  Typography.swift
//  The single place where a font size is written down.
//

import SwiftUI

/// Eight steps replace the twenty-one hand-written sizes the views used to
/// carry. A view may no longer call `.system(size:)`: when a size seems to be
/// missing, the answer is the nearest step, not a ninth one. `Tools/ui_lint.py`
/// fails the build if a bare size comes back.
///
/// Mapping used for the migration (kept here so the numbers stay auditable):
///
///   34 / 32 / 30 / 28            → display
///   22 / 20                      → figure
///   18 / 16 / 15 / 14 semibold   → title
///   14 / 13, and 12 medium+      → headline
///   12.5 / 12 regular            → body
///   11.5, 11 medium+             → label
///   11 regular / 10.5 / 10 reg.  → caption
///   10 medium+ / 9.5 / 9 / 8.5 / 8 → micro
enum Typography {
    /// The one hero figure on a screen: battery level, fan speed, health.
    static let display = Font.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit()
    /// A figure inside a card, one step below the hero.
    static let figure = Font.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit()
    /// Page and sheet titles.
    static let title = Font.system(size: 15, weight: .semibold)
    /// Card titles and section headers.
    static let headline = Font.system(size: 13, weight: .semibold)
    /// Body copy, settings rows, table cells.
    static let body = Font.system(size: 12, weight: .regular)
    /// Row labels, legends, button text.
    static let label = Font.system(size: 11, weight: .medium)
    /// Explanations, units, timestamps.
    static let caption = Font.system(size: 11, weight: .regular)
    /// Badges and unit suffixes only — never a sentence.
    static let micro = Font.system(size: 10, weight: .medium)
}

/// SF Symbols carry an optical size of their own, which is not a text size, so
/// glyphs get their own four steps instead of being folded into the ladder.
enum Glyph {
    /// Chevrons, disclosure arrows, dots inside a row.
    static let inline = Font.system(size: 10, weight: .medium)
    /// The icon that starts a row.
    static let row = Font.system(size: 12, weight: .medium)
    /// The icon that anchors a card header.
    static let block = Font.system(size: 18, weight: .medium)
    /// Empty-state and drop-zone artwork.
    static let hero = Font.system(size: 30, weight: .regular)
}
