import XCTest
@testable import SitboneCore
@testable import SitboneData

@MainActor
final class SessionProfileTests: XCTestCase {

    // MARK: - プロファイル作成

    func testCreateProfile() {
        let profile = SessionProfile(name: "coding")
        XCTAssertEqual(profile.name, "coding")
        XCTAssertEqual(profile.thresholds.driftDelay, 15)  // デフォルト値
        XCTAssertEqual(profile.thresholds.awayDelay, 90)
    }

    func testProfileHasUniqueID() {
        let codingProfile = SessionProfile(name: "coding")
        let writingProfile = SessionProfile(name: "writing")
        XCTAssertNotEqual(codingProfile.id, writingProfile.id)
    }

    func testProfileHasColor() {
        let profile = SessionProfile(name: "coding", colorHue: 0.5)
        XCTAssertEqual(profile.colorHue, 0.5)
    }

    func testDefaultProfile() {
        let profile = SessionProfile.makeDefault()
        XCTAssertEqual(profile.name, "default")
    }

    // MARK: - プロファイルのJSON永続化

    func testProfileCodable() throws {
        let original = SessionProfile(name: "coding", colorHue: 0.3)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionProfile.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, "coding")
        XCTAssertEqual(decoded.colorHue, 0.3)
    }

    func testProfileListCodable() throws {
        let profiles = [
            SessionProfile(name: "coding", colorHue: 0.3),
            SessionProfile(name: "writing", colorHue: 0.7)
        ]
        let data = try JSONEncoder().encode(profiles)
        let decoded = try JSONDecoder().decode([SessionProfile].self, from: data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].name, "coding")
        XCTAssertEqual(decoded[1].name, "writing")
    }

    // MARK: - SessionEngine プロファイル管理

    func testEngineHasDefaultProfile() {
        let engine = SessionEngine(deps: .test())
        engine.persistenceEnabled = false
        XCTAssertEqual(engine.activeProfile.name, "default")
        XCTAssertEqual(engine.profiles.count, 1)
    }

    func testCreateNewProfile() {
        let engine = SessionEngine(deps: .test())
        engine.persistenceEnabled = false
        engine.createProfile(name: "coding")
        XCTAssertEqual(engine.profiles.count, 2)
        XCTAssertEqual(engine.profiles[1].name, "coding")
    }

    func testSwitchProfile() {
        let engine = SessionEngine(deps: .test())
        engine.persistenceEnabled = false
        engine.startSession()

        let coding = engine.createProfile(name: "coding")
        engine.switchProfile(to: coding)

        XCTAssertEqual(engine.activeProfile.name, "coding")
        // セッション分割: カウンタとelapsedがリセット
        XCTAssertEqual(engine.focusedElapsed, 0)
        XCTAssertEqual(engine.totalElapsed, 0)
        XCTAssertEqual(engine.counters.driftRecovered.value, 0)
        // セッションは継続中
        XCTAssertTrue(engine.isSessionActive)
    }

    func testSwitchProfileChangesSiteObserver() {
        let engine = SessionEngine(deps: .test())
        engine.persistenceEnabled = false
        // defaultプロファイルでYouTubeをDRIFTに分類
        engine.classifySite("YouTube", as: .drift)
        let defaultObserver = engine.siteObserver
        XCTAssertEqual(defaultObserver.effectiveClassification(for: "YouTube"), .drift)

        // codingプロファイルに切替
        let coding = engine.createProfile(name: "coding")
        engine.switchProfile(to: coding)
        // siteObserverのインスタンスが変わっていることを確認
        XCTAssertTrue(engine.siteObserver !== defaultObserver)
        // 新プロファイルでは未分類
        XCTAssertEqual(engine.siteObserver.effectiveClassification(for: "YouTube"), .undecided)
    }

    func testDeleteProfile() {
        let engine = SessionEngine(deps: .test())
        engine.persistenceEnabled = false
        let coding = engine.createProfile(name: "coding")
        XCTAssertEqual(engine.profiles.count, 2)

        engine.deleteProfile(coding)
        XCTAssertEqual(engine.profiles.count, 1)
        XCTAssertEqual(engine.profiles[0].name, "default")
    }

    func testCannotDeleteActiveProfile() {
        let engine = SessionEngine(deps: .test())
        engine.persistenceEnabled = false
        let defaultProfile = engine.activeProfile
        engine.deleteProfile(defaultProfile)
        // アクティブプロファイルは削除できない
        XCTAssertEqual(engine.profiles.count, 1)
    }

    func testCannotDeleteLastProfile() {
        let engine = SessionEngine(deps: .test())
        engine.persistenceEnabled = false
        engine.deleteProfile(engine.activeProfile)
        XCTAssertEqual(engine.profiles.count, 1)  // 最後の1つは削除不可
    }
}
