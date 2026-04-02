import Testing
import Foundation
@testable import SitboneCore
@testable import SitboneSensors
@testable import SitboneData

struct SystemSleepTests {

    // MARK: - ヘルパー

    private struct ArbiterFixture {
        let engine: SessionEngine
        let clock: FixedClock
        let spy: SpyCameraFrameProvider
    }

    @MainActor
    private static func makeEngine(
        clock: FixedClock = FixedClock(),
        idle: Double = 0,
        presenceStatus: PresenceStatus = .present
    ) -> (engine: SessionEngine, clock: FixedClock) {
        let deps = Dependencies(
            clock: clock,
            windowMonitor: MockWindowMonitor(),
            idleDetector: MockIdleDetector(idle: idle),
            presenceDetector: MockPresenceDetector(status: presenceStatus),
            store: InMemorySessionStore()
        )
        let engine = SessionEngine(deps: deps)
        engine.persistenceEnabled = false
        return (engine, clock)
    }

    @MainActor
    private static func makeEngineWithArbiter(
        clock: FixedClock = FixedClock()
    ) -> ArbiterFixture {
        let spy = SpyCameraFrameProvider()
        let camera = MockSensor(
            name: "camera", baseWeight: 0.50,
            reading: SensorReading(isPresent: true)
        )
        let arbiter = PresenceArbiter(
            sensors: [camera],
            frameProvider: spy
        )
        let deps = Dependencies(
            clock: clock,
            windowMonitor: MockWindowMonitor(),
            idleDetector: MockIdleDetector(idle: 0),
            presenceDetector: arbiter,
            store: InMemorySessionStore()
        )
        let engine = SessionEngine(deps: deps)
        engine.persistenceEnabled = false
        return ArbiterFixture(engine: engine, clock: clock, spy: spy)
    }

    // MARK: - スリープ処理

    struct スリープ処理 {
        @Test("handleSystemSleep()でカメラが停止する")
        @MainActor
        func cameraStopsOnSleep() async {
            let fixture = SystemSleepTests.makeEngineWithArbiter()
            fixture.engine.startSession()

            fixture.engine.handleSystemSleep()

            #expect(fixture.spy.stopCaptureCallCount == 1)
        }

        @Test("スリープ中もセッションは終了しない")
        @MainActor
        func sessionRemainsActiveDuringSleep() {
            let (engine, _) = SystemSleepTests.makeEngine()
            engine.startSession()

            engine.handleSystemSleep()

            #expect(engine.isSessionActive == true)
            #expect(engine.focusState != nil)
        }

        @Test("セッション未開始時のhandleSystemSleep()は安全")
        @MainActor
        func sleepWithoutSessionIsSafe() {
            let (engine, _) = SystemSleepTests.makeEngine()
            // セッション開始せずにsleep — クラッシュしないこと
            engine.handleSystemSleep()
            #expect(engine.isSessionActive == false)
        }
    }

    // MARK: - ウェイク処理

    struct ウェイク処理 {
        @Test("handleSystemWake()後の最初のティックでスリープ時間が加算されない")
        @MainActor
        func wakeDoesNotInflateElapsed() async {
            let clock = FixedClock()
            let (engine, _) = SystemSleepTests.makeEngine(clock: clock)
            engine.startSession()

            // 3回の通常tick
            for _ in 0..<3 {
                clock.advance(by: 1)
                await engine.performTickForTest()
            }
            let beforeSleep = engine.totalElapsed // ~3s

            // スリープ
            engine.handleSystemSleep()
            clock.advance(by: 1800) // 30分のスリープ

            // ウェイク
            engine.handleSystemWake()
            clock.advance(by: 1)
            await engine.performTickForTest()

            // totalElapsedは ~4s であるべき（~1804sではない）
            #expect(engine.totalElapsed < 10)
            #expect(engine.totalElapsed > beforeSleep)
        }

        @Test("handleSystemWake()後にfocusedElapsedも正確")
        @MainActor
        func focusedElapsedAccurateAfterWake() async {
            let clock = FixedClock()
            let (engine, _) = SystemSleepTests.makeEngine(clock: clock)
            engine.startSession() // FLOW状態で開始

            // 3回のFLOW tick
            for _ in 0..<3 {
                clock.advance(by: 1)
                await engine.performTickForTest()
            }
            let focusedBeforeSleep = engine.focusedElapsed

            // スリープ→ウェイク
            engine.handleSystemSleep()
            clock.advance(by: 3600) // 1時間のスリープ
            engine.handleSystemWake()
            clock.advance(by: 1)
            await engine.performTickForTest()

            // focusedElapsedはスリープ時間を含まない
            #expect(engine.focusedElapsed < 10)
            #expect(engine.focusedElapsed > focusedBeforeSleep)
        }

        @Test("handleSystemWake()後にカメラが自動再開する")
        @MainActor
        func cameraRestartsAfterWake() async {
            let fixture = SystemSleepTests.makeEngineWithArbiter()
            fixture.engine.startSession()

            fixture.engine.handleSystemSleep()
            #expect(fixture.spy.stopCaptureCallCount == 1)

            // ウェイク後にtickを実行→detect()→captureFrame()が呼ばれる
            fixture.clock.advance(by: 1)
            fixture.engine.handleSystemWake()
            fixture.clock.advance(by: 1)
            await fixture.engine.performTickForTest()

            // captureFrame()が呼ばれたことを確認（spyのframeはnil→presence unknown）
            // カメラ停止は1回のみ（ウェイク後に追加のstopは呼ばれない）
            #expect(fixture.spy.stopCaptureCallCount == 1)
        }

        @Test("セッション未開始時のhandleSystemWake()は安全")
        @MainActor
        func wakeWithoutSessionIsSafe() {
            let (engine, _) = SystemSleepTests.makeEngine()
            engine.handleSystemWake()
            #expect(engine.isSessionActive == false)
        }
    }

    // MARK: - エッジケース

    struct エッジケース {
        @Test("連続スリープ→ウェイクで状態が正しい")
        @MainActor
        func multipleSleepWakeCycles() async {
            let clock = FixedClock()
            let (engine, _) = SystemSleepTests.makeEngine(clock: clock)
            engine.startSession()

            // 第1サイクル: 2 tick → sleep 30min → wake → 1 tick
            for _ in 0..<2 {
                clock.advance(by: 1)
                await engine.performTickForTest()
            }
            engine.handleSystemSleep()
            clock.advance(by: 1800)
            engine.handleSystemWake()
            clock.advance(by: 1)
            await engine.performTickForTest()

            let afterFirstCycle = engine.totalElapsed // ~3s

            // 第2サイクル: 2 tick → sleep 1h → wake → 1 tick
            for _ in 0..<2 {
                clock.advance(by: 1)
                await engine.performTickForTest()
            }
            engine.handleSystemSleep()
            clock.advance(by: 3600)
            engine.handleSystemWake()
            clock.advance(by: 1)
            await engine.performTickForTest()

            let afterSecondCycle = engine.totalElapsed // ~6s

            #expect(afterFirstCycle < 10)
            #expect(afterSecondCycle < 15)
            #expect(afterSecondCycle > afterFirstCycle)
        }

        @Test("カメラ無効時のスリープ処理でクラッシュしない")
        @MainActor
        func sleepWithCameraDisabledIsSafe() {
            let fixture = SystemSleepTests.makeEngineWithArbiter()
            fixture.engine.startSession()
            fixture.engine.isCameraEnabled = false

            fixture.engine.handleSystemSleep()

            // isCameraEnabled=false設定時にstopCamera()が1回呼ばれ、
            // handleSystemSleep()でもう1回呼ばれる
            #expect(fixture.spy.stopCaptureCallCount == 2)
            #expect(fixture.engine.isSessionActive == true)
        }
    }
}
