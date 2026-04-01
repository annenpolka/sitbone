import Testing
import Foundation
@testable import SitboneCore
@testable import SitboneSensors
@testable import SitboneData

struct SessionRecordCreationTests {
    private func makeDeps(clock: FixedClock) -> Dependencies {
        Dependencies(
            clock: clock,
            windowMonitor: MockWindowMonitor(),
            idleDetector: MockIdleDetector(idle: 0),
            presenceDetector: MockPresenceDetector(status: .absent),
            store: InMemorySessionStore()
        )
    }

    @Test("endSession()でSessionRecordが生成される")
    @MainActor
    func endSessionCreatesRecord() async {
        let clock = FixedClock()
        let engine = SessionEngine(deps: makeDeps(clock: clock))
        engine.persistenceEnabled = false
        engine.startSession()

        for _ in 0..<3 {
            clock.advance(by: 1)
            await engine.performTickForTest()
        }
        clock.advance(by: 1)
        engine.endSession()

        #expect(engine.lastSessionRecord != nil)
    }

    @Test("SessionRecordのフィールドが正確")
    @MainActor
    func sessionRecordFieldsAreCorrect() async {
        let clock = FixedClock()
        let engine = SessionEngine(deps: makeDeps(clock: clock))
        engine.persistenceEnabled = false
        engine.startSession()

        for _ in 0..<5 {
            clock.advance(by: 1)
            await engine.performTickForTest()
        }
        clock.advance(by: 1)
        engine.endSession()

        let record = engine.lastSessionRecord!
        #expect(record.type == "default")
        #expect(record.realElapsed >= 5.0)
        #expect(record.focusedElapsed >= 5.0)
        #expect(record.focusRatio > 0.9)
        #expect(record.driftRecovered == 0)
        #expect(record.awayRecovered == 0)
        #expect(record.deserted == 0)
    }

    @Test("SessionRecordにtimelineが含まれる")
    @MainActor
    func sessionRecordIncludesTimeline() async {
        let clock = FixedClock()
        let engine = SessionEngine(deps: makeDeps(clock: clock))
        engine.persistenceEnabled = false
        engine.startSession()

        for _ in 0..<3 {
            clock.advance(by: 1)
            await engine.performTickForTest()
        }
        clock.advance(by: 1)
        engine.endSession()

        let record = engine.lastSessionRecord!
        #expect(!record.timeline.isEmpty)
        #expect(record.timeline[0].state == FocusPhase.flow)
    }

    @Test("SessionRecordのtypeはアクティブプロファイル名")
    @MainActor
    func sessionRecordTypeIsProfileName() async {
        let clock = FixedClock()
        let engine = SessionEngine(deps: makeDeps(clock: clock))
        engine.persistenceEnabled = false

        let coding = engine.createProfile(name: "coding")
        engine.switchProfile(to: coding)

        engine.startSession()
        clock.advance(by: 1)
        await engine.performTickForTest()
        clock.advance(by: 1)
        engine.endSession()

        let record = engine.lastSessionRecord!
        #expect(record.type == "coding")
    }
}
