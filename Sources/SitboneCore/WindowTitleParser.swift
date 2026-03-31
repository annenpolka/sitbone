// WindowTitleParser — ウィンドウタイトルからサイト名を抽出

import Foundation

public enum WindowTitleParser {

    private static let browsers: Set<String> = [
        "Google Chrome", "Firefox", "Safari", "Arc",
        "Brave Browser", "Microsoft Edge", "Opera", "Vivaldi",
        "Chromium", "Orion",
    ]

    /// アプリ名がブラウザかどうか
    public static func isBrowser(_ appName: String) -> Bool {
        browsers.contains(appName)
    }

    /// ブラウザのウィンドウタイトルからサイト名を抽出
    /// "GitHub - annenpolka/sitbone - Google Chrome" → "GitHub"
    /// 非ブラウザの場合はnil
    public static func extractSiteName(from title: String, app: String) -> String? {
        guard isBrowser(app) else { return nil }

        // ブラウザのタイトル構造: "<page/site> - ... - <browser name>"
        // 最後のセパレータでブラウザ名を除去し、最初のセグメントをサイト名とする
        let separator = " - "
        var parts = title.components(separatedBy: separator)

        // 末尾がブラウザ名なら除去
        if let last = parts.last, last.trimmingCharacters(in: .whitespaces) == app {
            parts.removeLast()
        }

        // 最初のセグメント = サイト名（またはページ名）
        // "docs.rs - rand - Rust" → ["docs.rs", "rand", "Rust"] → "docs.rs"
        // "GitHub - annenpolka/sitbone · PR #3" → ["GitHub", "annenpolka/sitbone · PR #3"] → "GitHub"
        return parts.first?.trimmingCharacters(in: .whitespaces)
    }
}
