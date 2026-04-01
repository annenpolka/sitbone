// WindowTitleParser — ウィンドウタイトルからサイト名を抽出
// ADR-0009: デフォルト分類は廃止。Ghost Teacherのみで分類。

import Foundation

public enum WindowTitleParser {

    private static let browsers: Set<String> = [
        "Google Chrome", "Firefox", "Safari", "Arc",
        "Brave Browser", "Microsoft Edge", "Opera", "Vivaldi",
        "Chromium", "Orion"
    ]

    /// アプリ名がブラウザかどうか
    public static func isBrowser(_ appName: String) -> Bool {
        browsers.contains(appName)
    }

    /// ブラウザのウィンドウタイトルからサイト名を抽出
    public static func extractSiteName(from title: String, app: String) -> String? {
        guard isBrowser(app) else { return nil }
        let separator = " - "
        var parts = title.components(separatedBy: separator)
        if let last = parts.last, last.trimmingCharacters(in: .whitespaces) == app {
            parts.removeLast()
        }
        return parts.first?.trimmingCharacters(in: .whitespaces)
    }
}
