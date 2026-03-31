// SiteResolver — ブラウザタイトルからサイト名を安定して解決する
// ADR-0010: ハイブリッドアルゴリズム（既知サイト検索 + スコアリング）

import Foundation

// MARK: - SiteResolution（解決結果）

public struct SiteResolution: Sendable {
    public let site: String?          // 解決されたサイト名（nilならジャンク）
    public let confidence: Double     // 0.0-1.0
    public let candidates: [String]   // スコア順の候補リスト
}

// MARK: - TitleSegmenter（セパレータ分割）

public enum TitleSegmenter {
    /// タイトルを複数のセパレータで分割
    private static let separators = [" - ", " | ", " — ", " – ", " · ", " • "]

    public static func split(_ title: String) -> [String] {
        // 全セパレータを正規表現で同時に分割
        let pattern = separators
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [title.trimmingCharacters(in: .whitespaces)]
        }
        let range = NSRange(title.startIndex..., in: title)
        var lastEnd = title.startIndex
        var result: [String] = []

        regex.enumerateMatches(in: title, range: range) { match, _, _ in
            guard let matchRange = match?.range, let swiftRange = Range(matchRange, in: title) else { return }
            let segment = String(title[lastEnd..<swiftRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if !segment.isEmpty { result.append(segment) }
            lastEnd = swiftRange.upperBound
        }
        // 最後のセグメント
        let last = String(title[lastEnd...]).trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { result.append(last) }

        return result.isEmpty ? [title.trimmingCharacters(in: .whitespaces)] : result
    }
}

// MARK: - SegmentScorer（セグメントのスコアリング）

public enum SegmentScorer {
    private static let junk: Set<String> = [
        "new tab", "start page", "home", "untitled", "about:blank",
        "新しいタブ", "ホーム", "スタートページ",
    ]

    /// セグメントのサイト名らしさをスコアリング
    public static func score(_ segment: String, isFirst: Bool, isLast: Bool) -> Double {
        let lower = segment.lowercased()
        var s: Double = 0

        // ジャンク除外
        if junk.contains(lower) { return -100 }

        // ドメイン風（docs.rs, github.com等）: +3
        if segment.contains(".") && segment.count < 30 && !segment.contains(" ") {
            s += 3
        }

        // パス風（/を含む）: -3
        if segment.contains("/") { s -= 3 }
        // ハッシュ/アンカー: -1
        if segment.contains("#") { s -= 1 }

        // 単語数でスコアリング
        let words = segment.split(separator: " ")
        if words.count <= 3 {
            // 短いブランド名: +2
            s += 2
        } else {
            // 長い文章風: -1
            s -= 1
        }

        // 文字数が短い: +1
        if segment.count <= 20 { s += 1 }

        // 先頭/末尾ボーナス
        if isFirst { s += 0.5 }
        if isLast { s += 1.0 }  // 末尾の方が有力（YouTube, Stack Overflow型）

        return s
    }

    /// ジャンクかどうか
    public static func isJunk(_ segment: String) -> Bool {
        junk.contains(segment.lowercased())
    }
}

// MARK: - SiteResolver（統合解決）

public enum SiteResolver {
    /// ブラウザタイトルからサイト名を解決
    public static func resolve(
        title: String,
        app: String,
        observer: SiteObserver
    ) -> SiteResolution {
        // 1. セグメント分割
        var segments = TitleSegmenter.split(title)

        // 2. ブラウザ名とそれ以降を除去
        //    Chrome: "Page - Google Chrome - ProfileName" のパターン対応
        if let idx = segments.firstIndex(where: { $0.caseInsensitiveCompare(app) == .orderedSame }) {
            segments = Array(segments[..<idx])
        }

        // 3. ジャンクのみならnil
        let nonJunk = segments.filter { !SegmentScorer.isJunk($0) }
        if nonJunk.isEmpty {
            return SiteResolution(site: nil, confidence: 0, candidates: [])
        }

        // 4. 既知サイトをセグメントマッチで検索（主軸）
        if let known = observer.findKnownSite(inSegments: nonJunk) {
            return SiteResolution(site: known, confidence: 1.0, candidates: [known])
        }

        // 5. 未知サイト: スコアリングで候補を提案
        let scored = nonJunk.enumerated().map { (i, seg) -> (String, Double) in
            let isFirst = (i == 0)
            let isLast = (i == nonJunk.count - 1)
            return (seg, SegmentScorer.score(seg, isFirst: isFirst, isLast: isLast))
        }
        .sorted { $0.1 > $1.1 }

        let candidates = scored.map { $0.0 }
        let best = scored.first

        if let best, best.1 > 0 {
            let confidence = min(best.1 / 5.0, 1.0)
            return SiteResolution(site: best.0, confidence: confidence, candidates: candidates)
        }

        return SiteResolution(site: candidates.first, confidence: 0.1, candidates: candidates)
    }
}
