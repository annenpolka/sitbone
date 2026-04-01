import Testing
@testable import SitboneCore
@testable import SitboneSensors
@testable import SitboneData

struct TimelineTrackingTests {
    @Test("FLOW状態のみでtimelineに1ブロック記録される")
    @MainActor
    func singleFlowBlock() async {
        let clock = FixedClock()
        let deps = Dependencies.test(clock: clock, idleDetector: MockIdleDetector(idle: 0))
        let engine = SessionEngine(deps: deps)
        engine.persistenceEnabled = false
        engine.startSession()

        for _ in 0..<3 {
            clock.advance(by: 1)
            await engine.performTickForTest()
        }

        let blocks = engine.currentTimeline
        #expect(blocks.count == 1)
        #expect(blocks[0].state == FocusPhase.flow)
        #expect(blocks[0].duration >= 3.0)
    }

    @Test("phase遷移で複数ブロックが記録される")
    @MainActor
    func phaseTransitionCreatesMultipleBlocks() async {
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
        engine.startSession()

        // FLOW: 2 tick
        for _ in 0..<2 {
            clock.advance(by: 1)
            await engine.performTickForTest()
        }
        #expect(engine.focusState?.phase == .flow)

        // idle=20 → DRIFT遷移
        idleDetector.idle = 20
        clock.advance(by: 1)
        await engine.performTickForTest()
        #expect(engine.focusState?.phase == .drift, "tick後にDRIFTに遷移しているべき")

        // DRIFT: 2 tick
        for _ in 0..<2 {
            clock.advance(by: 1)
            await engine.performTickForTest()
        }

        let blocks = engine.currentTimeline
        #expect(blocks.count >= 2, "FLOWブロック+DRIFTブロックで2以上")
        if blocks.count >= 2 {
            #expect(blocks[0].state == FocusPhase.flow)
            #expect(blocks[1].state == FocusPhase.drift)
        }
    }

    @Test("startSession()でtimelineがリセットされる")
    @MainActor
    func startSessionResetsTimeline() async {
        let clock = FixedClock()
        let deps = Dependencies.test(clock: clock, idleDetector: MockIdleDetector(idle: 0))
        let engine = SessionEngine(deps: deps)
        engine.persistenceEnabled = false
        engine.startSession()

        clock.advance(by: 1)
        await engine.performTickForTest()
        #expect(!engine.currentTimeline.isEmpty)

        engine.endSession()
        engine.startSession()
        #expect(engine.currentTimeline.isEmpty)
    }

    @Test("flushTimeline()で現在のブロックが確定される")
    @MainActor
    func flushTimelineFinalizesCurrentBlock() async {
        let clock = FixedClock()
        let deps = Dependencies.test(clock: clock, idleDetector: MockIdleDetector(idle: 0))
        let engine = SessionEngine(deps: deps)
        engine.persistenceEnabled = false
        engine.startSession()

        clock.advance(by: 1)
        await engine.performTickForTest()
        clock.advance(by: 1)
        await engine.performTickForTest()

        let flushed = engine.flushTimeline()
        #expect(flushed.count == 1)
        #expect(flushed[0].state == FocusPhase.flow)
        #expect(flushed[0].duration >= 2.0)
    }
}
