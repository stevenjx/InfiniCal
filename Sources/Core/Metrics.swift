//
//  Metrics.swift
//  Spacing, corner radii and card padding on a 4 pt grid.
//

import SwiftUI

/// 4 pt grid. The values the views used to write by hand — 5, 6, 10, 14, 18 —
/// all fold into these steps.
enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
}

/// Three radii, down from eleven. Anything smaller than `chip` is a progress
/// bar and should be a `Capsule` instead.
///
/// There is no `sheet` step: macOS draws the sheet's own corner, so a token for
/// it never had — and never should have — a caller.
enum Radius {
    static let chip: CGFloat = 6
    static let control: CGFloat = 8
    static let card: CGFloat = 12
}

/// Two card insets, down from four. `regular` is the default; `compact` is for
/// dense grids where a 14 pt inset would eat the content.
enum CardPadding {
    static let none: CGFloat = 0
    static let compact: CGFloat = 10
    static let regular: CGFloat = 14
}

/// What a `Card` accepts for its inset. An enum rather than a `CGFloat` so the
/// two-value rule is enforced by the compiler: `Card(padding: 12)` no longer
/// compiles, where before it was a number nobody could see was off-grid.
enum CardInset {
    case regular
    case compact

    var value: CGFloat {
        switch self {
        case .regular: return CardPadding.regular
        case .compact: return CardPadding.compact
        }
    }
}
