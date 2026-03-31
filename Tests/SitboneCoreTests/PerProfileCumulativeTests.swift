import Testing
import Foundation
@testable import SitboneCore
@testable import SitboneSensors
@testable import SitboneData

struct PerProfileCumulativeTests {
    @Test("endSession()で累計が正しく加算される")
    @MainActor
    func endSessionAccumulatesCumulative() async {
        let clock = FixedClock()
        let deps = Dependencies(
            clock: clock,
            windowMonitor: MockWindowMonitor(),
            idleDetector: MockIdleDetector(idle: 0),
            presenceDetector: MockPresenceDetector(status: .absent),
            store: InMemorySessionStore()
        )
        let engine = SessionEngine(deps: deps)
        engine.persistenceEnabled = false
        engine.startSession()

        for _ in 0..<10 {
            clock.advance(by: 1)
            await engine.performTickForTest()
        }
        clock.advance(by: 1)
        engine.endSession()

        let cumulative = engine.cachedCumulative
        let expected = 10.0 / 3600.0
        #expect(abs(cumulative.totalFocusedHours - expected) < 0.001)
    }

    @Test("複数セッションで累計が蓄積される")
    @MainActor
    func multipleSessionsAccumulate() async {
        let clock = FixedClock()
        let deps = Dependencies(
            clock: clock,
            windowMonitor: MockWindowMonitor(),
            idleDetector: MockIdleDetector(idle: 0),
            presenceDetector: MockPresenceDetector(status: .absent),
            store: InMemorySessionStore()
        )
        let engine = SessionEngine(deps: deps)
        engine.persistenceEnabled = false

        // セッション1: 5秒
        engine.startSession()
        for _ in 0..<5 {
            clock.advance(by: 1)
            await engine.performTickForTest()
        }
        clock.advance(by: 1)
        engine.endSession()

        // セッション2: 10秒
        engine.startSession()
        for _ in 0..<10 {
            clock.advance(by: 1)
            await engine.performTickForTest()
        }
        clock.advance(by: 1)
        engine.endSession()

        let cumulative = engine.cachedCumulative
        let expected = 15.0 / 3600.0
        #expect(abs(cumulative.totalFocusedHours - expected) < 0.001)
    }

    @Test("二重計上が起きない")
    @MainActor
    func noDoubleCountingOnEndSession() async {
        let clock = FixedClock()
        let deps = Dependencies(
            clock: clock,
            windowMonitor: MockWindowMonitor(),
            idleDetector: MockIdleDetector(idle: 0),
            presenceDetector: MockPresenceDetector(status: .absent),
            store: InMemorySessionStore()
        )
        let engine = SessionEngine(deps: deps)
        engine.persistenceEnabled = false
        engine.startSession()

        for _ in 0..<5 {
            clock.advance(by: 1)
            await engine.performTickForTest()
        }
        clock.advance(by: 1)
        engine.endSession()

        let expected = 5.0 / 3600.0
        #expect(abs(engine.cachedCumulative.totalFocusedHours - expected) < 0.001,
                "focusedElapsedが二重に加算されてはいけない")
    }

    @Test("カウンタが上書きではなく累積される")
    @MainActor
    func countersAccumulateNotOverwrite() async {
        let clock = FixedClock()
        let idleDetector = MockIdleDetector(idle: 0)
        let deps = Dependencies(
            clock: clock,
            windowMonitor: MockWindowMonitor(),
            idleDetector: idleDetector,
            presenceDetector: MockPresenceDetector(status: .absent),
            store: InMemorySessionStore()
        )
        let engine = SessionEngine(deps: deps)
        engine.persistenceEnabled = false

        // セッション1: FLOW→DRIFT→FLOW (driftRecovered=1)
        engine.startSession()
        clock.advance(by: 1)
        await engine.performTickForTest()
        idleDetector.idle = 20
        clock.advance(by: 1)
        await engine.performTickForTest()
        idleDetector.idle = 0
        clock.advance(by: 1)
        await engine.performTickForTest()
        clock.advance(by: 1)
        engine.endSession()

        let after1 = engine.cachedCumulative.lifetimeDriftRecovered

        // セッション2: 同じパターン
        engine.startSession()
        clock.advance(by: 1)
        await engine.performTickForTest()
        idleDetector.idle = 20
        clock.advance(by: 1)
        await engine.performTickForTest()
        idleDetector.idle = 0
        clock.advance(by: 1)
        await engine.performTickForTest()
        clock.advance(by: 1)
        engine.endSession()

        let after2 = engine.cachedCumulative.lifetimeDriftRecovered
        #expect(after2 > after1, "2セッション目でカウンタが累積されるべき")
        #expect(after2 >= 2, "各セッションで少なくとも1回driftRecoveredが発生")
    }
}
