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

    // MARK: - ドメインパターンによるデフォルト分類

    private static let flowPatterns: [String] = [
        "GitHub", "GitLab", "Bitbucket",
        "Stack Overflow", "StackOverflow",
        "docs.rs", "developer.apple.com", "developer.mozilla.org",
        "MDN", "Hacker News",
        "Notion", "Obsidian", "Linear",
        "Figma", "Miro",
        "ChatGPT", "Claude",
        "Qiita", "Zenn",
    ]

    private static let driftPatterns: [String] = [
        "Twitter", "X", "𝕏",
        "Reddit", "Facebook", "Instagram", "TikTok",
        "YouTube", "Twitch", "Netflix", "Disney",
        "Amazon", "楽天",
        "Yahoo", "LINE",
        "Discord",
    ]

    /// サイト名からデフォルトのFLOW/DRIFT分類を返す（不明ならnil）
    public static func defaultClassification(for siteName: String) -> SiteSuggestion? {
        let lower = siteName.lowercased()
        for pattern in flowPatterns {
            if lower.contains(pattern.lowercased()) { return .flow }
        }
        for pattern in driftPatterns {
            if lower.contains(pattern.lowercased()) { return .drift }
        }
        return nil
    }
}
