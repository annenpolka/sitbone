import XCTest
@testable import SitboneCore

final class SiteResolutionTests: XCTestCase {

    // MARK: - セグメント分割（複数セパレータ対応）

    func testSplitDashSeparator() {
        let segments = TitleSegmenter.split("Video Title - YouTube - Google Chrome")
        XCTAssertEqual(segments, ["Video Title", "YouTube", "Google Chrome"])
    }

    func testSplitPipeSeparator() {
        let segments = TitleSegmenter.split("docs.rs | rand | Rust")
        XCTAssertEqual(segments, ["docs.rs", "rand", "Rust"])
    }

    func testSplitMDashSeparator() {
        let segments = TitleSegmenter.split("Article — Medium")
        XCTAssertEqual(segments, ["Article", "Medium"])
    }

    func testSplitMiddleDotSeparator() {
        let segments = TitleSegmenter.split("Issues · owner/repo · GitHub")
        XCTAssertEqual(segments, ["Issues", "owner/repo", "GitHub"])
    }

    // MARK: - 既知サイトのセグメントマッチ

    func testFindKnownSiteInSegments() {
        let observer = SiteObserver()
        observer.classify(site: "YouTube", as: .drift)

        let result = observer.findKnownSite(
            inSegments: ["Rick Astley - Never Gonna Give You Up", "YouTube"]
        )
        XCTAssertEqual(result, "YouTube")
    }

    func testFindKnownSiteNoFalsePositive() {
        let observer = SiteObserver()
        observer.classify(site: "GitHub", as: .flow)

        // "GitHub Copilot Tutorial" というセグメントでGitHubにマッチしてはいけない
        let result = observer.findKnownSite(
            inSegments: ["Watching GitHub Copilot Tutorial", "YouTube"]
        )
        XCTAssertNil(result)  // "YouTube"は未分類、"GitHub"はセグメント完全一致しない
    }

    func testFindKnownSiteExactSegmentMatch() {
        let observer = SiteObserver()
        observer.classify(site: "GitHub", as: .flow)

        let result = observer.findKnownSite(
            inSegments: ["GitHub", "annenpolka/sitbone"]
        )
        XCTAssertEqual(result, "GitHub")
    }

    func testFindKnownSiteLongestFirst() {
        let observer = SiteObserver()
        observer.classify(site: "Stack Overflow", as: .flow)
        observer.classify(site: "Stack", as: .drift)

        let result = observer.findKnownSite(
            inSegments: ["How to use async", "Stack Overflow"]
        )
        XCTAssertEqual(result, "Stack Overflow")  // "Stack"より"Stack Overflow"が優先
    }

    // MARK: - スコアリング（初回サイト名提案）

    func testScoreDomainLike() {
        let score = SegmentScorer.score("docs.rs", isFirst: true, isLast: false)
        let score2 = SegmentScorer.score("rand", isFirst: false, isLast: false)
        XCTAssertGreaterThan(score, score2)  // ドメイン風はスコアが高い
    }

    func testScoreShortBrand() {
        let score = SegmentScorer.score("YouTube", isFirst: false, isLast: true)
        let score2 = SegmentScorer.score("Rick Astley - Never Gonna Give You Up", isFirst: true, isLast: false)
        XCTAssertGreaterThan(score, score2)  // 短いブランド名 > 長いタイトル
    }

    func testScorePathLike() {
        let score = SegmentScorer.score("annenpolka/sitbone", isFirst: false, isLast: false)
        XCTAssertLessThanOrEqual(score, 0)  // パス風はゼロ以下
    }

    // MARK: - SiteResolution統合テスト

    func testResolveYouTube() {
        let observer = SiteObserver()
        observer.classify(site: "YouTube", as: .drift)

        let result = SiteResolver.resolve(
            title: "Rick Astley - Never Gonna Give You Up - YouTube - Google Chrome",
            app: "Google Chrome",
            observer: observer
        )
        XCTAssertEqual(result.site, "YouTube")
    }

    func testResolveGitHub() {
        let observer = SiteObserver()
        observer.classify(site: "GitHub", as: .flow)

        let result = SiteResolver.resolve(
            title: "GitHub - annenpolka/sitbone - Google Chrome",
            app: "Google Chrome",
            observer: observer
        )
        XCTAssertEqual(result.site, "GitHub")
    }

    func testResolveUnknownSiteSuggestsBestCandidate() {
        let observer = SiteObserver()  // 空、何も分類されていない

        let result = SiteResolver.resolve(
            title: "Video Title - YouTube - Google Chrome",
            app: "Google Chrome",
            observer: observer
        )
        // 未知サイト: YouTube がスコア最高で候補に入る
        XCTAssertTrue(result.candidates.contains("YouTube"))
        XCTAssertEqual(result.site, "YouTube")
    }

    func testResolveStackOverflow() {
        let observer = SiteObserver()

        let result = SiteResolver.resolve(
            title: "How to use async/await - Stack Overflow - Google Chrome",
            app: "Google Chrome",
            observer: observer
        )
        XCTAssertEqual(result.site, "Stack Overflow")
    }

    func testResolveDocsRs() {
        let observer = SiteObserver()

        let result = SiteResolver.resolve(
            title: "docs.rs - rand - Rust - Firefox",
            app: "Firefox",
            observer: observer
        )
        XCTAssertEqual(result.site, "docs.rs")
    }

    // MARK: - ジャンク除外

    func testResolveNewTab() {
        let observer = SiteObserver()

        let result = SiteResolver.resolve(
            title: "New Tab - Google Chrome",
            app: "Google Chrome",
            observer: observer
        )
        XCTAssertNil(result.site)
    }

    // MARK: - ブラウザアプリ抑制

    func testBrowserAppSuppressed() {
        XCTAssertTrue(WindowTitleParser.isBrowser("Google Chrome"))
        // ブラウザアプリ自体のGhost Teacherは不要（サイト単位で聞く）
    }
}
