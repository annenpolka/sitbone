import XCTest
@testable import SitboneCore
@testable import SitboneData
@testable import SitboneSensors

final class SiteAwareMachineTests: XCTestCase {

    // MARK: - DRIFTサイトにいるとidle関係なくDRIFT

    func testDriftSiteForcesDrift() async {
        let clock = FixedClock()
        let idle = MockIdleDetector(idle: 0)  // idle=0: 通常ならFLOW維持
        let deps = Dependencies(
            clock: clock,
            windowMonitor: MockWindowMonitor(),
            idleDetector: idle,
            presenceDetector: MockPresenceDetector(status: .present),
            store: InMemorySessionStore()
        )
        let machine = FocusStateMachine(deps: deps)
        let state = FocusState.flow(since: clock.now)

        // DRIFTサイトフラグをセット
        let (next, _, _) = await machine.tick(
            current: state, counters: Counters(), siteIsDrift: true
        )
        XCTAssertEqual(next.phase, .drift)
    }

    // MARK: - FLOWサイトでは通常判定

    func testFlowSiteUsesNormalLogic() async {
        let clock = FixedClock()
        let idle = MockIdleDetector(idle: 0)
        let deps = Dependencies(
            clock: clock,
            windowMonitor: MockWindowMonitor(),
            idleDetector: idle,
            presenceDetector: MockPresenceDetector(status: .present),
            store: InMemorySessionStore()
        )
        let machine = FocusStateMachine(deps: deps)
        let state = FocusState.flow(since: clock.now)

        let (next, _, _) = await machine.tick(
            current: state, counters: Counters(), siteIsDrift: false
        )
        XCTAssertEqual(next.phase, .flow)  // idle=0, present → FLOW維持
    }

    // MARK: - DRIFTサイトからFLOWサイトに戻るとFLOW復帰

    func testRecoveryFromDriftSite() async {
        let clock = FixedClock()
        let idle = MockIdleDetector(idle: 2)  // < flowRecovery
        let deps = Dependencies(
            clock: clock,
            windowMonitor: MockWindowMonitor(),
            idleDetector: idle,
            presenceDetector: MockPresenceDetector(status: .present),
            store: InMemorySessionStore()
        )
        let machine = FocusStateMachine(deps: deps)
        let state = FocusState.drift(since: clock.now)

        // DRIFTサイトではないので通常の復帰判定
        let (next, counters, _) = await machine.tick(
            current: state, counters: Counters(), siteIsDrift: false
        )
        XCTAssertEqual(next.phase, .flow)
        XCTAssertEqual(counters.driftRecovered.value, 1)
    }
}
