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
    /// siteIsDrift: 現在のアプリ/サイトがDRIFT分類されているか
    public func tick(
        current: FocusState,
        counters: Counters,
        siteIsDrift: Bool = false
    ) async -> (state: FocusState, counters: Counters) {
        let now = deps.clock.now
        let idle = deps.idleDetector.secondsSinceLastEvent()
        let presence = await deps.presenceDetector.detect()
        var counters = counters

        switch current {
        case .flow:
            // DRIFTサイトにいる → idle関係なく即DRIFT
            if siteIsDrift {
                return (.drift(since: now), counters)
            }
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
            // DRIFTサイトにいる間はDRIFTを維持（復帰させない）
            if siteIsDrift {
                let driftDuration = now.timeIntervalSince(current.since)
                if driftDuration > thresholds.t2, presence.status != .present {
                    counters.deserted.increment()
                    return (.away(since: now), counters)
                }
                return (current, counters)
            }
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
    @Published public private(set) var currentApp: String = ""
    @Published public private(set) var currentWindowTitle: String = ""
    @Published public private(set) var currentSite: String?  // ブラウザのサイト名
    @Published public private(set) var pendingGhostTeacher: String?  // 未分類サイト（Ghost Teacher待ち）

    public let siteObserver = SiteObserver()

    /// FLOW→DRIFT遷移時のコールバック (ADR-0007: 効果音用)
    public var onDriftEntered: (() -> Void)?

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

        let oldPhase = state.phase

        // 現在のサイト/アプリがDRIFT分類かチェック
        let isDriftSite: Bool = {
            if let site = currentSite {
                return siteObserver.effectiveClassification(for: site) == .drift
            }
            if !currentApp.isEmpty {
                return siteObserver.effectiveClassification(for: currentApp) == .drift
            }
            return false
        }()

        let (newState, newCounters) = await machine.tick(
            current: state, counters: counters, siteIsDrift: isDriftSite
        )
        let newPhase = newState.phase
        focusState = newState
        counters = newCounters

        // ウィンドウ情報更新
        currentApp = deps.windowMonitor.frontmostAppName() ?? ""
        currentWindowTitle = deps.windowMonitor.frontmostWindowTitle() ?? ""

        // アプリ使用をSiteObserverに記録（1tick = 1秒）
        if !currentApp.isEmpty {
            siteObserver.record(site: currentApp, phase: newPhase, duration: 1)
        }

        // ブラウザのサイト名抽出 + Ghost Teacher
        if WindowTitleParser.isBrowser(currentApp) {
            let site = WindowTitleParser.extractSiteName(from: currentWindowTitle, app: currentApp)
            // Ghost Teacher判定はrecordの前に（recordするとisNewSiteがfalseになる）
            if currentSite != site {
                currentSite = site
                if let site, siteObserver.isNewSite(site) {
                    pendingGhostTeacher = site
                }
            }
            // 記録はGhost Teacher判定の後
            if let site {
                siteObserver.record(site: site, phase: newPhase, duration: 1)
            }
        } else {
            currentSite = nil
            // pendingGhostTeacherはクリアしない（ユーザーの判定を待つ）
        }

        // FLOW→DRIFT遷移を検出してコールバック (ADR-0007)
        if oldPhase == .flow && newPhase == .drift {
            onDriftEntered?()
        }
    }

    /// Ghost Teacherの回答: サイトをFLOW/DRIFTに分類
    public func classifySite(_ site: String, as classification: SiteSuggestion) {
        siteObserver.classify(site: site, as: classification)
        if pendingGhostTeacher == site {
            pendingGhostTeacher = nil
        }
    }

    /// Ghost Teacherを無視
    public func dismissGhostTeacher() {
        pendingGhostTeacher = nil
    }

    public var focusRatio: Double {
        guard totalElapsed > 0 else { return 0 }
        return focusedElapsed / totalElapsed
    }
}
