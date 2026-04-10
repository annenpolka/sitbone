// FocusTransitionReasonTests — ADR-0018: tick戻り値のreason検証
//
// 各遷移ケースでpattern matchを行い、付随するcontext値が正しいことを確認する。

import Foundation
import Testing
@testable import SitboneCore
@testable import SitboneData
@testable import SitboneSensors

struct FocusTransitionReasonTests {

    // MARK: - Helpers

    private static func makeMachine(
        idle: Double,
        presence: PresenceStatus
    ) -> FocusStateMachine {
        let deps = Dependencies(
            clock: FixedClock(),
            windowMonitor: MockWindowMonitor(),
            idleDetector: MockIdleDetector(idle: idle),
            presenceDetector: MockPresenceDetector(status: presence),
            store: InMemorySessionStore()
        )
        return FocusStateMachine(deps: deps)
    }

    // MARK: - 遷移ありのケース: reasonが返される

    @Test("FLOW→DRIFT: idle超過 + 不在 → idleAbsent(idleSeconds)")
    func flowToDriftIdleAbsent() async {
        let machine = Self.makeMachine(idle: 20, presence: .absent)
        let initial = FocusState.flow(since: Date())

        let (next, _, reason) = await machine.tick(current: initial, counters: Counters())

        #expect(next.phase == .drift)
        guard case .idleAbsent(let idleSeconds) = reason else {
            Issue.record("expected .idleAbsent, got \(String(describing: reason))")
            return
        }
        #expect(idleSeconds == 20)
    }

    @Test("FLOW→DRIFT: idle大幅超 + 在席 → prolongedIdleWithPresence(idleSeconds)")
    func flowToDriftProlongedIdleWithPresence() async {
        let machine = Self.makeMachine(idle: 100, presence: .present)
        let initial = FocusState.flow(since: Date())

        let (next, _, reason) = await machine.tick(current: initial, counters: Counters())

        #expect(next.phase == .drift)
        guard case .prolongedIdleWithPresence(let idleSeconds) = reason else {
            Issue.record("expected .prolongedIdleWithPresence, got \(String(describing: reason))")
            return
        }
        #expect(idleSeconds == 100)
    }

    @Test("FLOW→AWAY: idle大幅超 + 不在 → desertion(idleSeconds)")
    func flowToAwayDesertion() async {
        let machine = Self.makeMachine(idle: 100, presence: .absent)
        let initial = FocusState.flow(since: Date())

        let (next, counters, reason) = await machine.tick(current: initial, counters: Counters())

        #expect(next.phase == .away)
        #expect(counters.deserted.value == 1)
        guard case .desertion(let idleSeconds) = reason else {
            Issue.record("expected .desertion, got \(String(describing: reason))")
            return
        }
        #expect(idleSeconds == 100)
    }

    @Test("FLOW→DRIFT: siteIsDrift → driftSite")
    func flowToDriftBySite() async {
        let machine = Self.makeMachine(idle: 0, presence: .present)
        let initial = FocusState.flow(since: Date())

        let (next, _, reason) = await machine.tick(
            current: initial,
            counters: Counters(),
            siteIsDrift: true
        )

        #expect(next.phase == .drift)
        guard case .driftSite = reason else {
            Issue.record("expected .driftSite, got \(String(describing: reason))")
            return
        }
    }

    @Test("DRIFT→FLOW: idle低下 → activityRecovered(idleSeconds)")
    func driftToFlowActivityRecovered() async {
        let machine = Self.makeMachine(idle: 2, presence: .present)
        let initial = FocusState.drift(since: Date())

        let (next, counters, reason) = await machine.tick(current: initial, counters: Counters())

        #expect(next.phase == .flow)
        #expect(counters.driftRecovered.value == 1)
        guard case .activityRecovered(let idleSeconds) = reason else {
            Issue.record("expected .activityRecovered, got \(String(describing: reason))")
            return
        }
        #expect(idleSeconds == 2)
    }

    @Test("AWAY→FLOW: idle低下 → activityRecovered(idleSeconds)")
    func awayToFlowActivityRecovered() async {
        let machine = Self.makeMachine(idle: 2, presence: .present)
        let initial = FocusState.away(since: Date())

        let (next, counters, reason) = await machine.tick(current: initial, counters: Counters())

        #expect(next.phase == .flow)
        #expect(counters.awayRecovered.value == 1)
        guard case .activityRecovered(let idleSeconds) = reason else {
            Issue.record("expected .activityRecovered, got \(String(describing: reason))")
            return
        }
        #expect(idleSeconds == 2)
    }

    @Test("DRIFT→AWAY: 長時間DRIFT + 不在 → driftTimeout(driftDuration)")
    func driftToAwayTimeout() async {
        let now = Date()
        let driftStart = now.addingTimeInterval(-200)  // awayDelay(90s)を大きく超える
        let clock = FixedClock(now)
        let deps = Dependencies(
            clock: clock,
            windowMonitor: MockWindowMonitor(),
            idleDetector: MockIdleDetector(idle: 100),
            presenceDetector: MockPresenceDetector(status: .absent),
            store: InMemorySessionStore()
        )
        let machine = FocusStateMachine(deps: deps)
        let initial = FocusState.drift(since: driftStart)

        let (next, counters, reason) = await machine.tick(current: initial, counters: Counters())

        #expect(next.phase == .away)
        #expect(counters.deserted.value == 1)
        guard case .driftTimeout(let driftDuration) = reason else {
            Issue.record("expected .driftTimeout, got \(String(describing: reason))")
            return
        }
        #expect(driftDuration == 200)
    }

    // MARK: - 遷移なしのケース: reasonはnil

    @Test("FLOW: idle低 → 遷移なし、reason=nil")
    func flowStaysReasonNil() async {
        let machine = Self.makeMachine(idle: 5, presence: .present)
        let initial = FocusState.flow(since: Date())

        let (next, _, reason) = await machine.tick(current: initial, counters: Counters())

        #expect(next.phase == .flow)
        #expect(reason == nil)
    }

    @Test("FLOW: 黙考シールド (idle中、在席) → 遷移なし、reason=nil")
    func flowContemplationReasonNil() async {
        let machine = Self.makeMachine(idle: 30, presence: .present)
        let initial = FocusState.flow(since: Date())

        let (next, _, reason) = await machine.tick(current: initial, counters: Counters())

        #expect(next.phase == .flow)
        #expect(reason == nil)
    }

    @Test("AWAY: idle高い → 遷移なし、reason=nil")
    func awayStaysReasonNil() async {
        let machine = Self.makeMachine(idle: 100, presence: .absent)
        let initial = FocusState.away(since: Date())

        let (next, _, reason) = await machine.tick(current: initial, counters: Counters())

        #expect(next.phase == .away)
        #expect(reason == nil)
    }
}

// MARK: - TransitionReason.name 検証

struct TransitionReasonNameTests {
    @Test("各reason caseに対応するnameが定義されている")
    func allCasesHaveName() {
        let cases: [(TransitionReason, String)] = [
            (.idleAbsent(idleSeconds: 0), "idle_absent"),
            (.prolongedIdleWithPresence(idleSeconds: 0), "prolonged_idle_with_presence"),
            (.desertion(idleSeconds: 0), "desertion"),
            (.driftSite, "drift_site"),
            (.activityRecovered(idleSeconds: 0), "activity_recovered"),
            (.driftTimeout(driftDuration: 0), "drift_timeout")
        ]
        for (reason, expected) in cases {
            #expect(reason.name == expected)
        }
    }
}
