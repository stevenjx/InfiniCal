//
//  L10n.swift
//  Runtime localisation.
//
//  The source language is Chinese, so a missing translation falls back to the
//  Chinese original instead of showing a key. English lives in `en.json` inside
//  the app bundle, keyed by the Chinese source string, which keeps the
//  translation table reviewable in one place and needs no rebuild to edit.
//

import Foundation

enum L10n {

    /// `nil` follows the system language; set by 设置 → 其他 → 语言.
    private static var override: Bool?

    static var isChinese: Bool {
        if let override { return override }
        let language = Locale.preferredLanguages.first ?? "en"
        return language.hasPrefix("zh")
    }

    /// 0 = follow the system, 1 = Chinese, 2 = English.
    static func applyPreference(_ mode: Int) {
        override = mode == 1 ? true : (mode == 2 ? false : nil)
    }

    /// Loaded once and kept even in Chinese so the language can be switched at
    /// runtime without relaunching.
    private static let table: [String: String] = {
        guard let url = Bundle.main.url(forResource: "en", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return map
    }()

    static func t(_ chinese: String) -> String {
        isChinese ? chinese : (table[chinese] ?? chinese)
    }

    /// Interpolated strings. `{p}` placeholders are filled left to right, so a
    /// translation can put them in a different order than the Chinese source.
    static func tf(_ chinese: String, _ values: [String]) -> String {
        var result = t(chinese)
        for value in values {
            guard let range = result.range(of: "{p}") else { break }
            result.replaceSubrange(range, with: value)
        }
        return result
    }
}

func t(_ chinese: String) -> String { L10n.t(chinese) }
func tf(_ chinese: String, _ values: String...) -> String { L10n.tf(chinese, values) }
