// SiteObserver — サイトごとのFLOW/DRIFT傾向を観測 + Ghost Teacher

public import Foundation
public import SitboneData

// MARK: - Suggestion

public enum SiteSuggestion: Equatable, Sendable {
    case flow
    case drift
    case undecided
}

// MARK: - Site Entry

public struct SiteEntry: Sendable {
    public var totalTime: TimeInterval
    public var flowTime: TimeInterval

    public init(totalTime: TimeInterval = 0, flowTime: TimeInterval = 0) {
        self.totalTime = totalTime
        self.flowTime = flowTime
    }

    public var flowRatio: Double {
        guard totalTime > 0 else { return 0.5 }
        return flowTime / totalTime
    }
}

// MARK: - SiteObserver

public final class SiteObserver: @unchecked Sendable {
    private var entries: [String: SiteEntry] = [:]
    /// ユーザーが明示的に分類したサイト (Ghost Teacher判定済み)
    private var userClassifications: [String: SiteSuggestion] = [:]
    private let threshold: Double = 0.7

    public init() {}

    // MARK: - 記録

    public func record(site: String, phase: FocusPhase, duration: TimeInterval) {
        var entry = entries[site] ?? SiteEntry()
        entry.totalTime += duration
        if phase == .flow {
            entry.flowTime += duration
        }
        entries[site] = entry
    }

    public func entry(for site: String) -> SiteEntry? {
        entries[site]
    }

    // MARK: - 自動サジェスト

    public func suggest(for site: String) -> SiteSuggestion {
        guard let entry = entries[site], entry.totalTime > 0 else {
            return .undecided
        }
        let ratio = entry.flowRatio
        if ratio >= threshold { return .flow }
        if ratio <= (1 - threshold) { return .drift }
        return .undecided
    }

    // MARK: - Ghost Teacher

    /// 初めて見るサイトかどうか（観測データもユーザー分類もない）
    public func isNewSite(_ site: String) -> Bool {
        entries[site] == nil && userClassifications[site] == nil
    }

    /// ユーザーがサイトを明示的に分類（Ghost Teacherの回答）
    public func classify(site: String, as classification: SiteSuggestion) {
        userClassifications[site] = classification
        // 観測データがなければ初期エントリを作成
        if entries[site] == nil {
            entries[site] = SiteEntry()
        }
    }

    /// ユーザーの明示分類を取得
    public func classification(for site: String) -> SiteSuggestion? {
        userClassifications[site]
    }

    /// 実効分類: ユーザー分類 > 自動サジェスト
    public func effectiveClassification(for site: String) -> SiteSuggestion {
        if let userClass = userClassifications[site] {
            return userClass
        }
        return suggest(for: site)
    }

    // MARK: - セグメントマッチ（ADR-0010）

    /// セグメント配列から既知サイトを検索
    /// 1. 完全一致（最優先、長い名前優先）
    /// 2. サブセグメント一致（"ホーム / Twitter" → "/" で分割して "Twitter" にマッチ）
    public func findKnownSite(inSegments segments: [String]) -> String? {
        let sorted = userClassifications.keys.sorted { $0.count > $1.count }

        // Pass 1: 完全一致
        for site in sorted {
            for segment in segments {
                if segment.caseInsensitiveCompare(site) == .orderedSame {
                    return site
                }
            }
        }

        // Pass 2: セグメント内のサブ分割（/ 区切り等）で一致
        for site in sorted {
            for segment in segments {
                let subsegments = segment.components(separatedBy: "/")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                for sub in subsegments {
                    if sub.caseInsensitiveCompare(site) == .orderedSame {
                        return site
                    }
                }
            }
        }

        return nil
    }

    // MARK: - 一覧

    public func allSuggestions() -> [(site: String, suggestion: SiteSuggestion, entry: SiteEntry)] {
        entries.map { (site: $0.key, suggestion: effectiveClassification(for: $0.key), entry: $0.value) }
            .sorted { $0.entry.totalTime > $1.entry.totalTime }
    }

    /// 全サイト名
    public var allSites: [String] {
        Array(Set(entries.keys).union(userClassifications.keys)).sorted()
    }

    // MARK: - 永続化

    /// ユーザー分類を辞書形式でエクスポート
    public func exportClassifications() -> [String: String] {
        var result: [String: String] = [:]
        for (site, classification) in userClassifications {
            switch classification {
            case .flow: result[site] = "flow"
            case .drift: result[site] = "drift"
            case .undecided: result[site] = "undecided"
            }
        }
        return result
    }

    /// 辞書形式からユーザー分類をインポート
    public func importClassifications(_ data: [String: String]) {
        for (site, value) in data {
            switch value {
            case "flow": userClassifications[site] = .flow
            case "drift": userClassifications[site] = .drift
            default: userClassifications[site] = .undecided
            }
            if entries[site] == nil {
                entries[site] = SiteEntry()
            }
        }
    }

    /// JSONにシリアライズ
    public func toJSON() throws -> Data {
        try JSONSerialization.data(withJSONObject: exportClassifications(), options: .prettyPrinted)
    }

    /// JSONからロード
    public func loadJSON(_ data: Data) throws {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return
        }
        importClassifications(dict)
    }
}
