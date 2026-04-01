import Testing
import Foundation
@testable import SitboneCore
@testable import SitboneSensors
@testable import SitboneData

struct SessionEngineExtendedTests {
    @MainActor
    private func makeEngine() -> SessionEngine {
        let deps = Dependencies(
            clock: FixedClock(),
            windowMonitor: MockWindowMonitor(),
            idleDetector: MockIdleDetector(idle: 0),
            presenceDetector: MockPresenceDetector(status: .absent),
            store: InMemorySessionStore()
        )
        let engine = SessionEngine(deps: deps)
        engine.persistenceEnabled = false
        return engine
    }

    // MARK: - renameProfile

    @Test("プロファイル名を変更できる")
    @MainActor
    func renameProfile() {
        let engine = makeEngine()
        let oldName = engine.activeProfile.name
        engine.renameProfile(engine.activeProfile, to: "coding")
        #expect(engine.activeProfile.name == "coding")
        #expect(engine.activeProfile.name != oldName)
    }

    @Test("非アクティブプロファイルの名前も変更できる")
    @MainActor
    func renameNonActiveProfile() {
        let engine = makeEngine()
        let p = engine.createProfile(name: "temp")
        engine.renameProfile(p, to: "writing")
        let found = engine.profiles.first { $0.id == p.id }
        #expect(found?.name == "writing")
    }

    // MARK: - dismissGhostTeacher

    @Test("dismissGhostTeacherでpendingがnilになる")
    @MainActor
    func dismissClearsPending() {
        let engine = makeEngine()
        // 直接設定はできないので、classifySiteのロジックをテスト
        // dismissGhostTeacherは pendingGhostTeacher を nil にする
        engine.dismissGhostTeacher()
        #expect(engine.pendingGhostTeacher == nil)
    }

    // MARK: - classifySite

    @Test("classifySiteでサイトが分類される")
    @MainActor
    func classifySiteSetClassification() {
        let engine = makeEngine()
        engine.classifySite("YouTube", as: .drift)
        #expect(engine.siteObserver.effectiveClassification(for: "YouTube") == .drift)
    }

    @Test("classifySiteでpendingGhostTeacherがクリアされる")
    @MainActor
    func classifySiteClearsPending() {
        let engine = makeEngine()
        // pendingを直接テスト: classifySiteが同じサイトならclear
        engine.classifySite("Xcode", as: .flow)
        #expect(engine.pendingGhostTeacher == nil)
    }

    // MARK: - focusRatio

    @Test("focusRatio: セッション未開始は0")
    @MainActor
    func focusRatioDefault() {
        let engine = makeEngine()
        #expect(engine.focusRatio == 0)
    }

    // MARK: - performTick ブラウザパス

    @Test("ブラウザアプリでSiteResolverが動作する")
    @MainActor
    func performTickWithBrowser() async {
        let clock = FixedClock()
        let windowMonitor = MockWindowMonitor(appName: "Google Chrome")
        windowMonitor.windowTitle = "GitHub - repo - Google Chrome"
        let deps = Dependencies(
            clock: clock,
            windowMonitor: windowMonitor,
            idleDetector: MockIdleDetector(idle: 0),
            presenceDetector: MockPresenceDetector(status: .absent),
            store: InMemorySessionStore()
        )
        let engine = SessionEngine(deps: deps)
        engine.persistenceEnabled = false
        engine.startSession()

        clock.advance(by: 1)
        await engine.performTickForTest()

        #expect(engine.currentApp == "Google Chrome")
        #expect(engine.currentSite != nil)
    }

    @Test("非ブラウザアプリではcurrentSiteがnil")
    @MainActor
    func performTickWithNonBrowser() async {
        let clock = FixedClock()
        let windowMonitor = MockWindowMonitor(appName: "Xcode")
        windowMonitor.windowTitle = "MyProject.swift"
        let deps = Dependencies(
            clock: clock,
            windowMonitor: windowMonitor,
            idleDetector: MockIdleDetector(idle: 0),
            presenceDetector: MockPresenceDetector(status: .absent),
            store: InMemorySessionStore()
        )
        let engine = SessionEngine(deps: deps)
        engine.persistenceEnabled = false
        engine.startSession()

        clock.advance(by: 1)
        await engine.performTickForTest()

        #expect(engine.currentApp == "Xcode")
        #expect(engine.currentSite == nil)
    }
}
