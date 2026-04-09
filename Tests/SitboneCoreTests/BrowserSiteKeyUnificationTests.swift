// BrowserSiteKeyUnificationTests — ADR-0016: URLドメイン最優先 + エイリアス機構
import Testing
import Foundation
@testable import SitboneCore
@testable import SitboneData
@testable import SitboneSensors

struct BrowserSiteKeyUnificationTests {

    // MARK: - URLドメイン最優先

    @Test("URLドメインが取得できる場合、タイトル由来が分類済みでもURLドメインをサイトキーにする")
    @MainActor
    func urlDomainTakesPrecedenceOverClassifiedTitle() async {
        let monitor = MockWindowMonitor(appName: "Google Chrome")
        monitor.windowTitle = "Zennの記事 - Zenn - Google Chrome"
        monitor.urlString = "https://zenn.dev/acn_jp_sdet/articles/6416085371f0ff"

        let engine = makeEngine(monitor: monitor)
        engine.siteObserver.classify(site: "Zenn", as: .flow)

        await engine.performTickForTest()

        #expect(engine.currentSite == "zenn.dev")
    }

    @Test("URLドメインが取得できない場合はタイトル由来にフォールバック")
    @MainActor
    func fallsBackToTitleWhenURLUnavailable() async {
        let monitor = MockWindowMonitor(appName: "Google Chrome")
        monitor.windowTitle = "動画タイトル - YouTube - Google Chrome"
        monitor.urlString = nil

        let engine = makeEngine(monitor: monitor)

        await engine.performTickForTest()

        #expect(engine.currentSite == "YouTube")
    }

    @Test("URLドメインが取得でき、どちらも未分類の場合、URLドメインがキーになる")
    @MainActor
    func urlDomainUsedWhenBothUnclassified() async {
        let monitor = MockWindowMonitor(appName: "Google Chrome")
        monitor.windowTitle = "記事タイトル - Zenn - Google Chrome"
        monitor.urlString = "https://zenn.dev/articles/123"

        let engine = makeEngine(monitor: monitor)

        await engine.performTickForTest()

        #expect(engine.currentSite == "zenn.dev")
    }

    @Test("URLドメイン分類済みの場合、Ghost Teacherが出ない")
    @MainActor
    func noGhostTeacherWhenDomainClassified() async {
        let monitor = MockWindowMonitor(appName: "Google Chrome")
        monitor.windowTitle = "新しい記事 - Zenn - Google Chrome"
        monitor.urlString = "https://zenn.dev/new-article"

        let engine = makeEngine(monitor: monitor)
        engine.siteObserver.classify(site: "zenn.dev", as: .flow)

        await engine.performTickForTest()

        #expect(engine.pendingGhostTeacher == nil)
        #expect(engine.currentSite == "zenn.dev")
    }

    @Test("YouTube: URLドメインが優先される")
    @MainActor
    func youtubeURLDomainPreferred() async {
        let monitor = MockWindowMonitor(appName: "Google Chrome")
        monitor.windowTitle = "Rick Astley - YouTube - Google Chrome"
        monitor.urlString = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

        let engine = makeEngine(monitor: monitor)
        engine.siteObserver.classify(site: "YouTube", as: .drift)

        await engine.performTickForTest()

        #expect(engine.currentSite == "youtube.com")
    }

    // MARK: - 共起エイリアス（SiteObserver単体）

    @Test("同一tickでURLドメインとタイトルが取れた場合エイリアスが記録される")
    @MainActor
    func aliasRecordedOnCooccurrence() async {
        let monitor = MockWindowMonitor(appName: "Google Chrome")
        monitor.windowTitle = "記事 - Zenn - Google Chrome"
        monitor.urlString = "https://zenn.dev/articles/123"

        let engine = makeEngine(monitor: monitor)

        await engine.performTickForTest()

        // "Zenn" が "zenn.dev" のエイリアスとして登録されている
        #expect(engine.siteObserver.domainForAlias("Zenn") == "zenn.dev")
    }

    @Test("エイリアス経由でドメインキーの分類を参照できる")
    @MainActor
    func aliasResolvesToDomainClassification() async {
        let monitor = MockWindowMonitor(appName: "Google Chrome")
        monitor.windowTitle = "記事 - Zenn - Google Chrome"
        monitor.urlString = "https://zenn.dev/articles/123"

        let engine = makeEngine(monitor: monitor)

        // 1tick目: エイリアス記録 + ドメイン分類
        await engine.performTickForTest()
        engine.siteObserver.classify(site: "zenn.dev", as: .flow)

        // "Zenn"で問い合わせても"zenn.dev"の分類が返る
        #expect(engine.siteObserver.classification(for: "Zenn") == .flow)
    }

    @Test("URL取得失敗時、エイリアス経由でドメインキーの分類を使いGhost Teacherが出ない")
    @MainActor
    func noGhostTeacherViaAliasWhenURLFails() async {
        let monitor = MockWindowMonitor(appName: "Google Chrome")
        monitor.windowTitle = "記事 - Zenn - Google Chrome"
        monitor.urlString = "https://zenn.dev/articles/123"

        let engine = makeEngine(monitor: monitor)

        // 1tick目: エイリアス記録
        await engine.performTickForTest()
        // classifySiteを使うことでpendingGhostTeacherもクリアされる
        engine.classifySite("zenn.dev", as: .flow)

        // 2tick目: URL取得失敗
        monitor.urlString = nil
        await engine.performTickForTest()

        // タイトル由来 "Zenn" がフォールバックで使われるが、
        // エイリアス経由で "zenn.dev" に解決され、分類済みなので ghost teacher は出ない
        #expect(engine.pendingGhostTeacher == nil)
        #expect(engine.currentSite == "zenn.dev")
    }

    @Test("タイトル由来で先に観測されたサイトは、後からURLが取れたらドメインキーへ統合される")
    @MainActor
    func titleFallbackObservationIsMergedIntoDomainWhenAliasIsLearned() async {
        let monitor = MockWindowMonitor(appName: "Google Chrome")
        monitor.windowTitle = "記事 - Zenn - Google Chrome"
        monitor.urlString = nil

        let engine = makeEngine(monitor: monitor)

        // 1tick目: URL取得失敗でタイトル由来キーを観測
        await engine.performTickForTest()
        #expect(engine.currentSite == "Zenn")

        // 2tick目: URL取得成功でドメインが判明
        monitor.urlString = "https://zenn.dev/articles/123"
        await engine.performTickForTest()

        let sites = Set(engine.siteObserver.allSuggestions().map(\.site))
        #expect(engine.currentSite == "zenn.dev")
        #expect(sites == Set(["zenn.dev"]))
    }

    @Test("タイトル由来で先に分類されたサイトは、後からURLが取れたらドメイン分類へ統合される")
    @MainActor
    func titleFallbackClassificationIsMergedIntoDomainWhenAliasIsLearned() async {
        let monitor = MockWindowMonitor(appName: "Google Chrome")
        monitor.windowTitle = "記事 - Zenn - Google Chrome"
        monitor.urlString = nil

        let engine = makeEngine(monitor: monitor)

        // 1tick目: URL取得失敗でタイトル由来キーを分類
        await engine.performTickForTest()
        engine.classifySite("Zenn", as: .flow)

        // 2tick目: URL取得成功でドメインが判明
        monitor.urlString = "https://zenn.dev/articles/123"
        await engine.performTickForTest()

        let classifications = engine.siteObserver.exportClassifications()
        #expect(engine.currentSite == "zenn.dev")
        #expect(engine.pendingGhostTeacher == nil)
        #expect(classifications["zenn.dev"] == "flow")
        #expect(classifications["Zenn"] == nil)
    }

    @Test("1ドメインに複数のタイトル名エイリアスを持てる")
    @MainActor
    func multipleTitleAliasesForOneDomain() async {
        let monitor = MockWindowMonitor(appName: "Google Chrome")

        let engine = makeEngine(monitor: monitor)

        // tick 1: "GitHub" タイトル
        monitor.windowTitle = "GitHub - annenpolka/sitbone - Google Chrome"
        monitor.urlString = "https://github.com/annenpolka/sitbone"
        await engine.performTickForTest()

        // tick 2: 別のタイトル
        monitor.windowTitle = "Pull requests · annenpolka/sitbone · GitHub - Google Chrome"
        monitor.urlString = "https://github.com/annenpolka/sitbone/pulls"
        await engine.performTickForTest()

        #expect(engine.siteObserver.domainForAlias("GitHub") == "github.com")
    }

    // MARK: - マイグレーション

    @Test("エイリアスを使ってタイトル由来キーの分類をドメインキーに移行できる")
    func migrateClassificationsToDomainKeys() {
        let observer = SiteObserver()

        // 旧データ: タイトル由来キーで分類されている
        observer.classify(site: "Zenn", as: .flow)
        observer.classify(site: "YouTube", as: .drift)

        // ロード済みエイリアスを想定
        observer.importAliases([
            "Zenn": "zenn.dev",
            "YouTube": "youtube.com"
        ])

        // マイグレーション実行
        let migrated = observer.migrateClassificationsToAliasedDomains()
        let exported = observer.exportClassifications()

        // ドメインキーに分類が移行されている
        #expect(observer.classification(for: "zenn.dev") == .flow)
        #expect(observer.classification(for: "youtube.com") == .drift)
        #expect(exported["Zenn"] == nil)
        #expect(exported["YouTube"] == nil)

        // 移行された件数
        #expect(migrated == 2)
    }

    @Test("ドメインキーに既に分類がある場合はタイトル由来キーを削除するのみ")
    func migrationDoesNotOverwriteExistingDomainClassification() {
        let observer = SiteObserver()

        // ドメインキーとタイトルキー両方に分類がある
        observer.classify(site: "zenn.dev", as: .drift)
        observer.classify(site: "Zenn", as: .flow)  // タイトル由来は異なる分類
        observer.importAliases(["Zenn": "zenn.dev"])

        let migrated = observer.migrateClassificationsToAliasedDomains()
        let exported = observer.exportClassifications()

        // ドメインキーの分類は上書きされない
        #expect(observer.classification(for: "zenn.dev") == .drift)
        #expect(exported["Zenn"] == nil)
        #expect(migrated == 0)
    }

    // MARK: - エイリアス永続化

    @Test("エイリアスがエクスポート・インポートできる")
    func aliasExportImport() {
        let observer = SiteObserver()
        observer.registerAlias(domain: "zenn.dev", titleSite: "Zenn")
        observer.registerAlias(domain: "youtube.com", titleSite: "YouTube")

        let exported = observer.exportAliases()
        #expect(exported["Zenn"] == "zenn.dev")
        #expect(exported["YouTube"] == "youtube.com")

        let observer2 = SiteObserver()
        observer2.importAliases(exported)
        #expect(observer2.domainForAlias("Zenn") == "zenn.dev")
        #expect(observer2.domainForAlias("YouTube") == "youtube.com")
    }

    // MARK: - Helper

    @MainActor
    private func makeEngine(monitor: MockWindowMonitor) -> SessionEngine {
        let deps = Dependencies(
            clock: FixedClock(),
            windowMonitor: monitor,
            idleDetector: MockIdleDetector(idle: 0),
            presenceDetector: MockPresenceDetector(status: .present),
            store: InMemorySessionStore()
        )
        let engine = SessionEngine(deps: deps)
        engine.persistenceEnabled = false
        engine.startSession()
        return engine
    }
}
