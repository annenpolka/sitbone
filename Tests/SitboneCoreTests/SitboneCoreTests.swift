import XCTest
@testable import SitboneCore
@testable import SitboneData
@testable import SitboneSensors

final class FocusStateMachineTests: XCTestCase {

    func testFlowStaysWhenIdleBelowT1() async {
        let clock = FixedClock()
        let idle = MockIdleDetector(idle: 5)
        let deps = Dependencies(
            clock: clock,
            windowMonitor: MockWindowMonitor(),
            idleDetector: idle,
            presenceDetector: MockPresenceDetector(status: .present),
            store: InMemorySessionStore()
        )
        let machine = FocusStateMachine(deps: deps)
        let initial = FocusState.flow(since: clock.now)

        let (next, _) = await machine.tick(current: initial, counters: Counters())
        XCTAssertEqual(next.phase, .flow)
    }

    func testFlowToDriftWhenIdleAboveT1AndAbsent() async {
        let clock = FixedClock()
        let idle = MockIdleDetector(idle: 20)
        let deps = Dependencies(
            clock: clock,
            windowMonitor: MockWindowMonitor(),
            idleDetector: idle,
            presenceDetector: MockPresenceDetector(status: .absent),
            store: InMemorySessionStore()
        )
        let machine = FocusStateMachine(deps: deps)
        let initial = FocusState.flow(since: clock.now)

        let (next, _) = await machine.tick(current: initial, counters: Counters())
        XCTAssertEqual(next.phase, .drift)
    }

    func testDriftToFlowRecoversDriftCounter() async {
        let clock = FixedClock()
        let idle = MockIdleDetector(idle: 2) // < flowRecovery(5s)
        let deps = Dependencies(
            clock: clock,
            windowMonitor: MockWindowMonitor(),
            idleDetector: idle,
            presenceDetector: MockPresenceDetector(status: .present),
            store: InMemorySessionStore()
        )
        let machine = FocusStateMachine(deps: deps)
        let initial = FocusState.drift(since: clock.now)

        let (next, counters) = await machine.tick(current: initial, counters: Counters())
        XCTAssertEqual(next.phase, .flow)
        XCTAssertEqual(counters.driftRecovered.value, 1)
    }

    func testAwayRecoveryIncrementsCounter() async {
        let clock = FixedClock()
        let idle = MockIdleDetector(idle: 2)
        let deps = Dependencies(
            clock: clock,
            windowMonitor: MockWindowMonitor(),
            idleDetector: idle,
            presenceDetector: MockPresenceDetector(status: .present),
            store: InMemorySessionStore()
        )
        let machine = FocusStateMachine(deps: deps)
        let initial = FocusState.away(since: clock.now)

        let (next, counters) = await machine.tick(current: initial, counters: Counters())
        XCTAssertEqual(next.phase, .flow)
        XCTAssertEqual(counters.awayRecovered.value, 1)
    }
}
