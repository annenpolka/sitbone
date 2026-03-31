// SitboneCore — 状態マシン + セッション管理

public import Foundation
public import Combine
public import SitboneData
public import SitboneSensors

// MARK: - FocusState (不正な遷移を型で排除)

public enum FocusState: Sendable, Equatable {
    case flow(since: Date)
    case drift(since: Date)
    case away(since: Date)

    public var phase: FocusPhase {
        switch self {
        case .flow: .flow
        case .drift: .drift
        case .away: .away
        }
    }

    public var since: Date {
        switch self {
        case .flow(let d), .drift(let d), .away(let d): d
        }
    }
}

// MARK: - Dependencies

public struct Dependencies: Sendable {
    public let clock: any ClockProtocol
    public let windowMonitor: any WindowMonitorProtocol
    public let idleDetector: any IdleDetectorProtocol
    public let presenceDetector: any PresenceDetectorProtocol
    public let store: any SessionStoreProtocol

    public init(
        clock: any ClockProtocol,
        windowMonitor: any WindowMonitorProtocol,
        idleDetector: any IdleDetectorProtocol,
        presenceDetector: any PresenceDetectorProtocol,
        store: any SessionStoreProtocol
    ) {
        self.clock = clock
        self.windowMonitor = windowMonitor
        self.idleDetector = idleDetector
        self.presenceDetector = presenceDetector
        self.store = store
    }

    public static let live = Dependencies(
        clock: SystemClock(),
        windowMonitor: NSWorkspaceWindowMonitor(),
        idleDetector: CGEventSourceIdleDetector(),
        presenceDetector: MockPresenceDetector(status: .unknown),
        store: InMemorySessionStore()
    )
}

// MARK: - Thresholds

public struct Thresholds: Sendable {
    public let t1: TimeInterval  // FLOW→DRIFT (15s)
    public let t2: TimeInterval  // DRIFT→AWAY (90s)
    public let flowRecovery: TimeInterval  // FLOW復帰に必要なactivity (5s)

    public init(t1: TimeInterval = 15, t2: TimeInterval = 90, flowRecovery: TimeInterval = 5) {
        self.t1 = t1
        self.t2 = t2
        self.flowRecovery = flowRecovery
    }
}

// MARK: - Counters

public struct Counters: Sendable, Equatable {
    public var driftRecovered = Counter()
    public var awayRecovered = Counter()
    public var deserted = Counter()

    public init() {}
}

// MARK: - FocusStateMachine

public final class FocusStateMachine: Sendable {
    private let deps: Dependencies
    private let thresholds: Thresholds

    public init(deps: Dependencies, thresholds: Thresholds = Thresholds()) {
        self.deps = deps
        self.thresholds = thresholds
    }

    /// 現在のセンサー値に基づき次の状態を計算する
    public func tick(
        current: FocusState,
        counters: Counters
    ) async -> (state: FocusState, counters: Counters) {
        let now = deps.clock.now
        let idle = deps.idleDetector.secondsSinceLastEvent()
        let presence = await deps.presenceDetector.detect()
        var counters = counters

        switch current {
        case .flow:
            if idle < thresholds.t1 {
                return (current, counters)
            }
            if idle < thresholds.t2 {
                if presence.status == .present {
                    return (current, counters)
                }
                return (.drift(since: now), counters)
            }
            if presence.status == .present {
                return (.drift(since: now), counters)
            }
            counters.deserted.increment()
            return (.away(since: now), counters)

        case .drift:
            if idle < thresholds.flowRecovery {
                counters.driftRecovered.increment()
                return (.flow(since: now), counters)
            }
            let driftDuration = now.timeIntervalSince(current.since)
            if driftDuration > thresholds.t2, presence.status != .present {
                counters.deserted.increment()
                return (.away(since: now), counters)
            }
            return (current, counters)

        case .away:
            if idle < thresholds.flowRecovery {
                counters.awayRecovered.increment()
                return (.flow(since: now), counters)
            }
            return (current, counters)
        }
    }
}

// MARK: - SessionEngine (セッション全体を管理、UI層とのブリッジ)

@MainActor
public final class SessionEngine: ObservableObject {
    @Published public private(set) var focusState: FocusState?
    @Published public private(set) var counters = Counters()
    @Published public private(set) var isSessionActive = false
    @Published public private(set) var sessionStartedAt: Date?
    @Published public private(set) var focusedElapsed: TimeInterval = 0
    @Published public private(set) var totalElapsed: TimeInterval = 0

    private let deps: Dependencies
    private let machine: FocusStateMachine
    private var tickTask: Task<Void, Never>?
    private var lastTickTime: Date?

    public init(deps: Dependencies) {
        self.deps = deps
        self.machine = FocusStateMachine(deps: deps)
    }

    public func startSession() {
        let now = deps.clock.now
        focusState = .flow(since: now)
        counters = Counters()
        isSessionActive = true
        sessionStartedAt = now
        focusedElapsed = 0
        totalElapsed = 0
        lastTickTime = now

        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.performTick()
            }
        }
    }

    public func endSession() {
        tickTask?.cancel()
        tickTask = nil
        isSessionActive = false
        focusState = nil
        lastTickTime = nil
    }

    private func performTick() async {
        guard let state = focusState else { return }
        let now = deps.clock.now

        if let last = lastTickTime {
            let delta = now.timeIntervalSince(last)
            totalElapsed += delta
            if state.phase == .flow {
                focusedElapsed += delta
            }
        }
        lastTickTime = now

        let (newState, newCounters) = await machine.tick(
            current: state, counters: counters
        )
        focusState = newState
        counters = newCounters
    }

    public var focusRatio: Double {
        guard totalElapsed > 0 else { return 0 }
        return focusedElapsed / totalElapsed
    }
}
