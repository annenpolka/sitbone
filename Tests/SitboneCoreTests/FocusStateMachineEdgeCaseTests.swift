import Testing
import Foundation
@testable import SitboneCore
@testable import SitboneSensors
@testable import SitboneData

struct FocusStateMachineEdgeCaseTests {
    private func makeMachine(idle: Double, presence: PresenceStatus = .absent) -> (FocusStateMachine, Dependencies) {
        let clock = FixedClock()
        let deps = Dependencies(
            clock: clock,
            windowMonitor: MockWindowMonitor(),
            idleDetector: MockIdleDetector(idle: idle),
            presenceDetector: MockPresenceDetector(status: presence),
            store: InMemorySessionStore()
        )
        let machine = FocusStateMachine(deps: deps)
        return (machine, deps)
    }

    // MARK: - FLOW → AWAY 直接遷移

    @Test("idle >= T2 かつ absent → FLOW→AWAY + deserted++")
    func flowToAwayDirectTransition() async {
        let (machine, deps) = makeMachine(idle: 100, presence: .absent) // > t2(90)
        let state = FocusState.flow(since: deps.clock.now)
        let (newState, counters) = await machine.tick(current: state, counters: Counters())
        #expect(newState.phase == .away)
        #expect(counters.deserted.value == 1)
    }

    @Test("idle >= T2 かつ present → FLOW→DRIFT（黙考）")
    func flowToDriftWhenPresentAboveT2() async {
        let (machine, deps) = makeMachine(idle: 100, presence: .present)
        let state = FocusState.flow(since: deps.clock.now)
        let (newState, counters) = await machine.tick(current: state, counters: Counters())
        #expect(newState.phase == .drift)
        #expect(counters.deserted.value == 0)
    }

    // MARK: - DRIFT + siteIsDrift

    @Test("DRIFTサイト滞在中にT2超過 + absent → AWAY")
    func driftSiteTimeoutToAway() async {
        let clock = FixedClock()
        let deps = Dependencies(
            clock: clock,
            windowMonitor: MockWindowMonitor(),
            idleDetector: MockIdleDetector(idle: 20),
            presenceDetector: MockPresenceDetector(status: .absent),
            store: InMemorySessionStore()
        )
        let machine = FocusStateMachine(deps: deps)
        // driftが始まったのが91秒前(> t2=90)
        let driftStart = clock.now.addingTimeInterval(-91)
        let state = FocusState.drift(since: driftStart)
        let (newState, counters) = await machine.tick(
            current: state, counters: Counters(), siteIsDrift: true
        )
        #expect(newState.phase == .away)
        #expect(counters.deserted.value == 1)
    }

    @Test("DRIFTサイト滞在中にT2超過 + present → DRIFT維持")
    func driftSiteTimeoutButPresent() async {
        let clock = FixedClock()
        let deps = Dependencies(
            clock: clock,
            windowMonitor: MockWindowMonitor(),
            idleDetector: MockIdleDetector(idle: 20),
            presenceDetector: MockPresenceDetector(status: .present),
            store: InMemorySessionStore()
        )
        let machine = FocusStateMachine(deps: deps)
        let driftStart = clock.now.addingTimeInterval(-91)
        let state = FocusState.drift(since: driftStart)
        let (newState, _) = await machine.tick(
            current: state, counters: Counters(), siteIsDrift: true
        )
        #expect(newState.phase == .drift)
    }

    @Test("DRIFTサイト滞在中にT2未満 → DRIFT維持")
    func driftSiteBelowT2StaysDrift() async {
        let clock = FixedClock()
        let deps = Dependencies(
            clock: clock,
            windowMonitor: MockWindowMonitor(),
            idleDetector: MockIdleDetector(idle: 20),
            presenceDetector: MockPresenceDetector(status: .absent),
            store: InMemorySessionStore()
        )
        let machine = FocusStateMachine(deps: deps)
        let driftStart = clock.now.addingTimeInterval(-10) // < t2
        let state = FocusState.drift(since: driftStart)
        let (newState, _) = await machine.tick(
            current: state, counters: Counters(), siteIsDrift: true
        )
        #expect(newState.phase == .drift)
    }

    // MARK: - DRIFT → AWAY (通常)

    @Test("DRIFT中にT2超過 + absent → AWAY")
    func driftTimeoutToAway() async {
        let clock = FixedClock()
        let deps = Dependencies(
            clock: clock,
            windowMonitor: MockWindowMonitor(),
            idleDetector: MockIdleDetector(idle: 20),
            presenceDetector: MockPresenceDetector(status: .absent),
            store: InMemorySessionStore()
        )
        let machine = FocusStateMachine(deps: deps)
        let driftStart = clock.now.addingTimeInterval(-91)
        let state = FocusState.drift(since: driftStart)
        let (newState, counters) = await machine.tick(current: state, counters: Counters())
        #expect(newState.phase == .away)
        #expect(counters.deserted.value == 1)
    }

    // MARK: - AWAY 維持

    @Test("AWAY中にidle継続 → AWAY維持")
    func awayStaysWhenIdle() async {
        let (machine, deps) = makeMachine(idle: 30, presence: .absent)
        let state = FocusState.away(since: deps.clock.now)
        let (newState, _) = await machine.tick(current: state, counters: Counters())
        #expect(newState.phase == .away)
    }
}
