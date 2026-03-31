import XCTest
@testable import SitboneCore
@testable import SitboneData

final class SiteObserverTests: XCTestCase {

    // MARK: - サイト観測の記録

    func testRecordFlowVisit() {
        let observer = SiteObserver()
        observer.record(site: "GitHub", phase: .flow, duration: 60)
        let entry = observer.entry(for: "GitHub")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.flowTime, 60)
        XCTAssertEqual(entry?.totalTime, 60)
    }

    func testRecordDriftVisit() {
        let observer = SiteObserver()
        observer.record(site: "Twitter", phase: .drift, duration: 30)
        let entry = observer.entry(for: "Twitter")
        XCTAssertEqual(entry?.flowTime, 0)
        XCTAssertEqual(entry?.totalTime, 30)
    }

    func testAccumulateVisits() {
        let observer = SiteObserver()
        observer.record(site: "docs.rs", phase: .flow, duration: 100)
        observer.record(site: "docs.rs", phase: .flow, duration: 50)
        observer.record(site: "docs.rs", phase: .drift, duration: 20)
        let entry = observer.entry(for: "docs.rs")!
        XCTAssertEqual(entry.totalTime, 170)
        XCTAssertEqual(entry.flowTime, 150)
    }

    // MARK: - サジェスト生成

    func testSuggestFlow() {
        let observer = SiteObserver()
        observer.record(site: "docs.rs", phase: .flow, duration: 300)
        observer.record(site: "docs.rs", phase: .drift, duration: 10)
        let suggestion = observer.suggest(for: "docs.rs")
        XCTAssertEqual(suggestion, .flow)
    }

    func testSuggestDrift() {
        let observer = SiteObserver()
        observer.record(site: "Twitter", phase: .drift, duration: 200)
        observer.record(site: "Twitter", phase: .flow, duration: 5)
        let suggestion = observer.suggest(for: "Twitter")
        XCTAssertEqual(suggestion, .drift)
    }

    func testSuggestUndecidedWithNoData() {
        let observer = SiteObserver()
        let suggestion = observer.suggest(for: "unknown.com")
        XCTAssertEqual(suggestion, .undecided)
    }

    func testSuggestUndecidedWithEvenData() {
        let observer = SiteObserver()
        observer.record(site: "reddit", phase: .flow, duration: 50)
        observer.record(site: "reddit", phase: .drift, duration: 50)
        let suggestion = observer.suggest(for: "reddit")
        XCTAssertEqual(suggestion, .undecided)
    }

    // MARK: - Ghost Teacher: 未分類サイト検出

    func testUnknownSiteIsNew() {
        let observer = SiteObserver()
        XCTAssertTrue(observer.isNewSite("YouTube"))
    }

    func testKnownSiteIsNotNew() {
        let observer = SiteObserver()
        observer.record(site: "YouTube", phase: .drift, duration: 10)
        XCTAssertFalse(observer.isNewSite("YouTube"))
    }

    func testClassifySite() {
        let observer = SiteObserver()
        observer.classify(site: "YouTube", as: .drift)
        XCTAssertEqual(observer.classification(for: "YouTube"), .drift)
        XCTAssertFalse(observer.isNewSite("YouTube"))
    }

    func testClassifiedSiteOverridesSuggestion() {
        let observer = SiteObserver()
        observer.record(site: "YouTube", phase: .flow, duration: 300)
        // 自動サジェストはflowだが、ユーザーがdriftに分類
        observer.classify(site: "YouTube", as: .drift)
        XCTAssertEqual(observer.effectiveClassification(for: "YouTube"), .drift)
    }

    func testEffectiveClassificationFallsBackToSuggestion() {
        let observer = SiteObserver()
        observer.record(site: "docs.rs", phase: .flow, duration: 300)
        // ユーザー分類なし → サジェストを使う
        XCTAssertEqual(observer.effectiveClassification(for: "docs.rs"), .flow)
    }
}
