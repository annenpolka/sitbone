// SiteObserver — サイトごとのFLOW/DRIFT傾向を観測・サジェスト

public import Foundation
public import SitboneData

// MARK: - Suggestion

public enum SiteSuggestion: Equatable, Sendable {
    case flow       // 70%以上がFLOW → FLOW推奨
    case drift      // 70%以上がDRIFT → DRIFT推奨
    case undecided  // データ不足 or 判定困難
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
    private let threshold: Double = 0.7  // 70%以上でFLOW/DRIFT判定

    public init() {}

    /// サイト訪問を記録
    public func record(site: String, phase: FocusPhase, duration: TimeInterval) {
        var entry = entries[site] ?? SiteEntry()
        entry.totalTime += duration
        if phase == .flow {
            entry.flowTime += duration
        }
        entries[site] = entry
    }

    /// サイトの観測データを取得
    public func entry(for site: String) -> SiteEntry? {
        entries[site]
    }

    /// サイトの分類をサジェスト
    public func suggest(for site: String) -> SiteSuggestion {
        guard let entry = entries[site], entry.totalTime > 0 else {
            return .undecided
        }
        let ratio = entry.flowRatio
        if ratio >= threshold { return .flow }
        if ratio <= (1 - threshold) { return .drift }
        return .undecided
    }

    /// 全サイトのサジェスト一覧
    public func allSuggestions() -> [(site: String, suggestion: SiteSuggestion, entry: SiteEntry)] {
        entries.map { (site: $0.key, suggestion: suggest(for: $0.key), entry: $0.value) }
            .sorted { $0.entry.totalTime > $1.entry.totalTime }
    }
}
