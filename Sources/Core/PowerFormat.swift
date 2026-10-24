//
//  PowerFormat.swift
//  One place that decides how a watt value is rendered.
//
//  The UI used to mix "%.2f W" (diagram labels) with "%.1f W" (header chips),
//  which made the same number look like two different readings. Everything now
//  goes through `PowerFormat.watts`, so a value is always shown with exactly one
//  decimal and never flickers between precisions.
//

import Foundation

enum PowerFormat {

    /// Canonical watt string: one decimal, e.g. `24.2 W`.
    /// Values below 0.05 W collapse to `—` so an idle branch reads as "nothing
    /// flowing" instead of "0.0 W".
    static func watts(_ value: Double?, zero: String = "—") -> String {
        guard let value, value.isFinite else { return "—" }
        let magnitude = abs(value)
        if magnitude < 0.05 { return zero }
        return String(format: "%.1f W", value)
    }

    /// As above but with an explicit sign (used by the battery chip).
    static func signedWatts(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude < 0.05 { return "+0.0 W" }
        return String(format: "%@%.1f W", value >= 0 ? "+" : "-", magnitude)
    }

    /// Watt string for a reading. The quality is deliberately NOT encoded in the
    /// text any more: an "≈" in front of roughly half the numbers was noise. The
    /// measured/estimated distinction lives in the tooltip and the data-source card.
    static func watts(_ value: Double?, quality: PowerQuality) -> String {
        _ = quality
        return watts(value)
    }
}