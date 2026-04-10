// swiftlint:disable file_length
// SitboneCore — 状態マシン + セッション管理

public import Foundation
public import Combine
import os
public import SitboneData
public import SitboneSensors

// MARK: - DriftSoundSetting (ADR-0017)

struct DriftSoundSetting: Codable {
    var soundName: String?
}

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
        case .flow(let date), .drift(let date), .away(let date): date
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

    public static let live: Dependencies = {
        let frameProvider = AVCameraFrameProvider()
        let camera = CameraDetector(frameProvider: frameProvider)
        let gaze = GazeDetector(frameProvider: frameProvider)
        let logsDir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".sitbone/logs")
        let arbiter = PresenceArbiter(
            sensors: [camera, gaze],
            csvLogger: PresenceCSVLogger(directory: logsDir),
            frameProvider: frameProvider
        )
        return Dependencies(
            clock: SystemClock(),
            windowMonitor: NSWorkspaceWindowMonitor(),
            idleDetector: CGEventSourceIdleDetector(),
            presenceDetector: arbiter,
            store: InMemorySessionStore()
        )
    }()

    public static func test(
        clock: any ClockProtocol = FixedClock(),
        windowMonitor: any WindowMonitorProtocol = MockWindowMonitor(),
        idleDetector: any IdleDetectorProtocol = MockIdleDetector(),
        presenceDetector: any PresenceDetectorProtocol = MockPresenceDetector(),
        store: any SessionStoreProtocol = InMemorySessionStore()
    ) -> Dependencies {
        Dependencies(
            clock: clock,
            windowMonitor: windowMonitor,
            idleDetector: idleDetector,
            presenceDetector: presenceDetector,
            store: store
        )
    }
}

// MARK: - Thresholds

public struct Thresholds: Sendable {
    public let driftDelay: TimeInterval  // FLOW→DRIFT (15s)
    public let awayDelay: TimeInterval  // DRIFT→AWAY (90s)
    public let flowRecovery: TimeInterval  // FLOW復帰に必要なactivity (5s)

    public init(
        driftDelay: TimeInterval = 15,
        awayDelay: TimeInterval = 90,
        flowRecovery: TimeInterval = 5
    ) {
        self.driftDelay = driftDelay
        self.awayDelay = awayDelay
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

private struct TickSnapshot {
    let now: Date
    let idle: TimeInterval
    let presence: PresenceReading
}

// MARK: - TransitionReason (ADR-0018)

/// FocusState遷移の理由と根拠値。
/// 遷移が発生したときのみnon-nilで返される。
public enum TransitionReason: Sendable {
    /// FLOW→DRIFT: idleがdriftDelayを超え、presenceも検知できない（活動停止）
    case idleAbsent(idleSeconds: Double)

    /// FLOW→DRIFT: idleがawayDelayを超えても在席は検知（黙考シールドの打ち切り）
    case prolongedIdleWithPresence(idleSeconds: Double)

    /// FLOW→AWAY: idleがawayDelayを超え、presenceも検知できない（離席）
    case desertion(idleSeconds: Double)

    /// FLOW→DRIFT: 現在のサイト/アプリがdrift分類されている
    case driftSite

    /// DRIFT→FLOW or AWAY→FLOW: ユーザー活動が再開した
    case activityRecovered(idleSeconds: Double)

    /// DRIFT→AWAY: drift状態が長時間続き、presenceも検知できない
    case driftTimeout(driftDuration: Double)

    public var name: String {
        switch self {
        case .idleAbsent:                return "idle_absent"
        case .prolongedIdleWithPresence: return "prolonged_idle_with_presence"
        case .desertion:                 return "desertion"
        case .driftSite:                 return "drift_site"
        case .activityRecovered:         return "activity_recovered"
        case .driftTimeout:              return "drift_timeout"
        }
    }
}

// swiftlint:disable:next large_tuple
public typealias TickResult = (state: FocusState, counters: Counters, reason: TransitionReason?)

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
    ) async -> TickResult {
        let snapshot = TickSnapshot(
            now: deps.clock.now,
            idle: deps.idleDetector.secondsSinceLastEvent(),
            presence: await deps.presenceDetector.detect()
        )

        switch current {
        case .flow:
            return tickFlow(
                current: current,
                counters: counters,
                snapshot: snapshot,
                siteIsDrift: siteIsDrift
            )

        case .drift:
            return tickDrift(
                current: current,
                counters: counters,
                snapshot: snapshot,
                siteIsDrift: siteIsDrift
            )

        case .away:
            return tickAway(current: current, counters: counters, snapshot: snapshot)
        }
    }

    private func tickFlow(
        current: FocusState,
        counters: Counters,
        snapshot: TickSnapshot,
        siteIsDrift: Bool
    ) -> TickResult {
        var updatedCounters = counters

        if siteIsDrift {
            return (.drift(since: snapshot.now), updatedCounters, .driftSite)
        }
        if snapshot.idle < thresholds.driftDelay {
            return (current, updatedCounters, nil)
        }
        if snapshot.idle < thresholds.awayDelay {
            if snapshot.presence.status == .present {
                return (current, updatedCounters, nil)
            }
            return (
                .drift(since: snapshot.now),
                updatedCounters,
                .idleAbsent(idleSeconds: snapshot.idle)
            )
        }
        if snapshot.presence.status == .present {
            return (
                .drift(since: snapshot.now),
                updatedCounters,
                .prolongedIdleWithPresence(idleSeconds: snapshot.idle)
            )
        }
        updatedCounters.deserted.increment()
        return (
            .away(since: snapshot.now),
            updatedCounters,
            .desertion(idleSeconds: snapshot.idle)
        )
    }

    private func tickDrift(
        current: FocusState,
        counters: Counters,
        snapshot: TickSnapshot,
        siteIsDrift: Bool
    ) -> TickResult {
        var updatedCounters = counters

        if siteIsDrift {
            return driftOrAwayState(
                current: current,
                counters: updatedCounters,
                snapshot: snapshot
            )
        }
        if snapshot.idle < thresholds.flowRecovery {
            updatedCounters.driftRecovered.increment()
            return (
                .flow(since: snapshot.now),
                updatedCounters,
                .activityRecovered(idleSeconds: snapshot.idle)
            )
        }
        return driftOrAwayState(
            current: current,
            counters: updatedCounters,
            snapshot: snapshot
        )
    }

    private func tickAway(
        current: FocusState,
        counters: Counters,
        snapshot: TickSnapshot
    ) -> TickResult {
        var updatedCounters = counters
        if snapshot.idle < thresholds.flowRecovery {
            updatedCounters.awayRecovered.increment()
            return (
                .flow(since: snapshot.now),
                updatedCounters,
                .activityRecovered(idleSeconds: snapshot.idle)
            )
        }
        return (current, updatedCounters, nil)
    }

    private func driftOrAwayState(
        current: FocusState,
        counters: Counters,
        snapshot: TickSnapshot
    ) -> TickResult {
        var updatedCounters = counters
        let driftDuration = snapshot.now.timeIntervalSince(current.since)
        if driftDuration > thresholds.awayDelay, snapshot.presence.status != .present {
            updatedCounters.deserted.increment()
            return (
                .away(since: snapshot.now),
                updatedCounters,
                .driftTimeout(driftDuration: driftDuration)
            )
        }
        return (current, updatedCounters, nil)
    }
}

// MARK: - SessionEngine (セッション全体を管理、UI層とのブリッジ)

@MainActor
// swiftlint:disable type_body_length
public final class SessionEngine: ObservableObject {
    @Published public private(set) var focusState: FocusState?
    @Published public private(set) var counters = Counters()
    @Published public private(set) var isSessionActive = false
    @Published public private(set) var sessionStartedAt: Date?
    @Published public private(set) var focusedElapsed: TimeInterval = 0
    @Published public private(set) var totalElapsed: TimeInterval = 0
    @Published public private(set) var currentApp: String = ""
    @Published public private(set) var currentWindowTitle: String = ""
    @Published public private(set) var currentSite: String?
    @Published public private(set) var pendingGhostTeacher: String?
    @Published public var cumulativeFocusedHours: Double = 0
    /// プロファイル別累計キャッシュ (ADR-0012)
    @Published public private(set) var cachedCumulative = CumulativeRecord()

    // MARK: - プロファイル管理 (ADR-0011)
    @Published public private(set) var activeProfile: SessionProfile
    @Published public private(set) var profiles: [SessionProfile]
    public private(set) var siteObserver: SiteObserver
    /// プロファイル別SiteObserverのキャッシュ
    private var siteObservers: [UUID: SiteObserver] = [:]
    /// プロファイル別SessionStoreのキャッシュ (ADR-0012)
    private var profileStores: [UUID: any SessionStoreProtocol] = [:]

    /// カメラによるpresence検出の有効/無効
    @Published public var isCameraEnabled: Bool = true {
        didSet {
            guard oldValue != isCameraEnabled else { return }
            if let arbiter = deps.presenceDetector as? PresenceArbiter {
                arbiter.isEnabled = isCameraEnabled
                if !isCameraEnabled {
                    arbiter.stopCamera()
                }
            }
            Logger.coreSession.info(
                "camera presence \(self.isCameraEnabled ? "enabled" : "disabled", privacy: .public)"
            )
        }
    }

    /// Ghost Teacherの自動消去までの秒数（0で無効）
    @Published public var ghostTeacherAutoDismissSeconds: Double = 10

    /// Ghost Teacherのキーバインド設定
    @Published public var ghostTeacherKeyBindings = GhostTeacherKeyBindings() {
        didSet { saveGhostTeacherKeyBindings() }
    }

    /// DRIFT遷移時の効果音名（nilで無効） (ADR-0017)
    @Published public var driftSoundName: String? = "Tink" {
        didSet { saveDriftSoundSetting() }
    }

    /// FLOW→DRIFT遷移時のコールバック (ADR-0007: 効果音用)
    public var onDriftEntered: (() -> Void)?

    private let deps: Dependencies
    private let machine: FocusStateMachine
    private let persistenceRoot: URL
    private var tickTask: Task<Void, Never>?
    private var lastTickTime: Date?

    // MARK: - Timeline tracking (ADR-0012)
    private var timelineBlocks: [TimelineBlock] = []
    private var currentTimelinePhase: FocusPhase?
    private var currentPhaseDuration: TimeInterval = 0

    public init(deps: Dependencies, persistenceRoot: URL? = nil) {
        self.deps = deps
        let resolvedPersistenceRoot = persistenceRoot ?? Self.defaultPersistenceRoot()
        try? FileManager.default.createDirectory(
            at: resolvedPersistenceRoot,
            withIntermediateDirectories: true
        )
        self.persistenceRoot = resolvedPersistenceRoot
        let defaultProfile = SessionProfile.makeDefault()
        self.activeProfile = defaultProfile
        self.profiles = [defaultProfile]
        let observer = SiteObserver()
        self.siteObserver = observer
        self.siteObservers[defaultProfile.id] = observer
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
        timelineBlocks = []
        currentTimelinePhase = nil
        currentPhaseDuration = 0

        Logger.coreSession.info("session started profile=\(self.activeProfile.name, privacy: .private)")

        startTickLoop()
    }

    // MARK: - システムスリープ/ウェイク (ADR-0015)

    /// スリープ前にカメラ停止 + tickループ停止
    public func handleSystemSleep() {
        guard isSessionActive else { return }
        Logger.coreLifecycle.info("system sleep")
        // スリープ境界までの経過時間を確定
        if let state = focusState {
            let now = deps.clock.now
            let delta = advanceElapsed(phase: state.phase, now: now)
            updateTimeline(phase: state.phase, delta: delta)
            lastTickTime = now
        }
        // カメラ停止
        if let arbiter = deps.presenceDetector as? PresenceArbiter {
            arbiter.stopCamera()
        }
        // tickループ停止
        tickTask?.cancel()
        tickTask = nil
    }

    /// ウェイク後にlastTickTimeリセット + tickループ再開
    public func handleSystemWake() {
        guard isSessionActive else { return }
        Logger.coreLifecycle.info("system wake")
        // スリープ時間を破棄するためlastTickTimeをリセット
        lastTickTime = deps.clock.now
        // tickループ再開（カメラは遅延起動で自動復帰）
        startTickLoop()
    }

    private func startTickLoop() {
        tickTask?.cancel()
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

        // カメラセッション停止
        if let arbiter = deps.presenceDetector as? PresenceArbiter {
            arbiter.stopCamera()
        }

        // SessionRecord生成 (ADR-0012)
        let timeline = flushTimeline()
        if let startedAt = sessionStartedAt {
            let now = deps.clock.now
            let record = SessionRecord(
                type: activeProfile.name,
                startedAt: startedAt,
                endedAt: now,
                realElapsed: totalElapsed,
                focusedElapsed: focusedElapsed,
                focusRatio: focusRatio,
                driftRecovered: counters.driftRecovered.value,
                awayRecovered: counters.awayRecovered.value,
                deserted: counters.deserted.value,
                timeline: timeline
            )
            lastSessionRecord = record
            saveSessionRecord(record)
        }

        Logger.coreSession.info("""
            session ended profile=\(self.activeProfile.name, privacy: .private) \
            focused=\(self.focusedElapsed, privacy: .public)s \
            total=\(self.totalElapsed, privacy: .public)s \
            ratio=\(self.focusRatio, privacy: .public) \
            deserted=\(self.counters.deserted.value, privacy: .public) \
            driftRecovered=\(self.counters.driftRecovered.value, privacy: .public) \
            awayRecovered=\(self.counters.awayRecovered.value, privacy: .public)
            """)

        // セッション累積データを保存
        saveCumulativeData()

        focusState = nil
        lastTickTime = nil
    }

    private func performTick() async {
        guard let state = focusState else { return }
        let now = deps.clock.now
        let oldPhase = state.phase
        let delta = advanceElapsed(phase: oldPhase, now: now)
        updateTimeline(phase: oldPhase, delta: delta)
        lastTickTime = now

        let (newState, newCounters, reason) = await machine.tick(
            current: state,
            counters: counters,
            siteIsDrift: isCurrentTargetDriftSite()
        )
        let newPhase = newState.phase
        focusState = newState
        counters = newCounters

        if oldPhase != newPhase, let reason {
            logTransition(from: oldPhase, to: newPhase, reason: reason, counters: newCounters)
        }

        refreshWindowContext(for: newPhase)
        triggerDriftCallbackIfNeeded(from: oldPhase, to: newPhase)
    }

    /// FocusState遷移をcore.stateカテゴリに記録する (ADR-0018)
    private func logTransition(
        from oldPhase: FocusPhase,
        to newPhase: FocusPhase,
        reason: TransitionReason,
        counters: Counters
    ) {
        switch reason {
        case .idleAbsent(let idle),
             .prolongedIdleWithPresence(let idle),
             .desertion(let idle),
             .activityRecovered(let idle):
            Logger.coreState.info("""
                transition \(oldPhase.rawValue, privacy: .public) → \(newPhase.rawValue, privacy: .public) \
                reason=\(reason.name, privacy: .public) idle=\(idle, privacy: .public)s \
                deserted=\(counters.deserted.value, privacy: .public) \
                driftRecovered=\(counters.driftRecovered.value, privacy: .public) \
                awayRecovered=\(counters.awayRecovered.value, privacy: .public)
                """)
        case .driftTimeout(let duration):
            Logger.coreState.info("""
                transition \(oldPhase.rawValue, privacy: .public) → \(newPhase.rawValue, privacy: .public) \
                reason=\(reason.name, privacy: .public) duration=\(duration, privacy: .public)s \
                deserted=\(counters.deserted.value, privacy: .public)
                """)
        case .driftSite:
            let site = self.currentSite ?? self.currentApp
            Logger.coreState.info("""
                transition \(oldPhase.rawValue, privacy: .public) → \(newPhase.rawValue, privacy: .public) \
                reason=\(reason.name, privacy: .public) site=\(site, privacy: .private)
                """)
        }
    }

    private func advanceElapsed(phase: FocusPhase, now: Date) -> TimeInterval {
        guard let lastTickTime else { return 0 }
        let delta = now.timeIntervalSince(lastTickTime)
        totalElapsed += delta
        if phase == .flow {
            focusedElapsed += delta
        }
        return delta
    }

    private func updateTimeline(phase: FocusPhase, delta: TimeInterval) {
        if currentTimelinePhase == phase {
            currentPhaseDuration += delta
            return
        }
        if let previousPhase = currentTimelinePhase, currentPhaseDuration > 0 {
            timelineBlocks.append(
                TimelineBlock(state: previousPhase, duration: currentPhaseDuration)
            )
        }
        currentTimelinePhase = phase
        currentPhaseDuration = delta
    }

    private func isCurrentTargetDriftSite() -> Bool {
        if let site = currentSite {
            return siteObserver.effectiveClassification(for: site) == .drift
        }
        if !currentApp.isEmpty {
            return siteObserver.effectiveClassification(for: currentApp) == .drift
        }
        return false
    }

    private func refreshWindowContext(for phase: FocusPhase) {
        let previousApp = currentApp
        currentApp = deps.windowMonitor.frontmostAppName() ?? ""
        currentWindowTitle = deps.windowMonitor.frontmostWindowTitle() ?? ""

        if WindowTitleParser.isBrowser(currentApp) {
            updateBrowserContext(for: phase)
            return
        }

        updateAppContext(previousApp: previousApp, phase: phase)
    }

    private func updateBrowserContext(for phase: FocusPhase) {
        let resolution = SiteResolver.resolve(
            title: currentWindowTitle,
            app: currentApp,
            observer: siteObserver
        )
        let browserSiteKey = BrowserSiteIdentity.canonicalSiteKey(
            urlString: deps.windowMonitor.frontmostWindowURL()
        )

        // ADR-0016: 同一tickで両方取れた場合にエイリアスを記録
        if let domain = browserSiteKey, let titleSite = resolution.site {
            siteObserver.registerAlias(domain: domain, titleSite: titleSite)
        }

        let site = preferredBrowserSiteKey(
            browserSiteKey: browserSiteKey,
            titleResolvedSite: resolution.site
        )

        updateCurrentSite(site)
        if let site {
            siteObserver.record(site: site, phase: phase, duration: 1)
        }
    }

    private func updateAppContext(previousApp: String, phase: FocusPhase) {
        currentSite = nil
        if currentApp != previousApp && !currentApp.isEmpty {
            dismissedSites.remove(currentApp)
            if siteObserver.isUnclassified(currentApp) && !dismissedSites.contains(currentApp) {
                pendingGhostTeacher = currentApp
            }
        }
        if !currentApp.isEmpty {
            siteObserver.record(site: currentApp, phase: phase, duration: 1)
        }
    }

    private func updateCurrentSite(_ site: String?) {
        guard currentSite != site else { return }
        currentSite = site
        guard let site else { return }

        dismissedSites.remove(site)
        if siteObserver.isUnclassified(site) && !dismissedSites.contains(site) {
            pendingGhostTeacher = site
        }
    }

    private func triggerDriftCallbackIfNeeded(from oldPhase: FocusPhase, to newPhase: FocusPhase) {
        if oldPhase == .flow && newPhase == .drift {
            onDriftEntered?()
        }
    }

    // MARK: - プロファイル操作

    /// 新規プロファイルを作成
    @discardableResult
    public func createProfile(name: String, colorHue: Double = Double.random(in: 0...1)) -> SessionProfile {
        let profile = SessionProfile(name: name, colorHue: colorHue)
        profiles.append(profile)
        siteObservers[profile.id] = SiteObserver()
        saveProfiles()
        return profile
    }

    /// プロファイルを切替（セッション分割）
    public func switchProfile(to profile: SessionProfile) {
        guard profiles.contains(where: { $0.id == profile.id }) else { return }
        guard profile.id != activeProfile.id else { return }

        Logger.coreSession.info("""
            profile switched \(self.activeProfile.name, privacy: .private) \
            → \(profile.name, privacy: .private)
            """)

        if persistenceEnabled {
            saveClassificationsForActiveProfile()
        }
        if isSessionActive {
            saveActiveSessionForProfileSwitch()
        }

        // プロファイル切替: SiteObserverを差し替え
        activeProfile = profile
        let newObserver = siteObservers[profile.id] ?? SiteObserver()
        siteObserver = newObserver
        if siteObservers[profile.id] == nil {
            siteObservers[profile.id] = newObserver
        }

        if isSessionActive {
            resetSessionForProfileSwitch()
        }

        // 新プロファイルの累計をロード（クロス汚染防止）
        cachedCumulative = CumulativeRecord()
        cumulativeFocusedHours = 0
        if persistenceEnabled {
            loadClassificationsForProfile(profile)
            loadCumulativeData()
        }
    }

    /// プロファイル切替時に、現プロファイルのセッションを保存する
    private func saveActiveSessionForProfileSwitch() {
        let timeline = flushTimeline()
        if let startedAt = sessionStartedAt {
            let now = deps.clock.now
            let record = SessionRecord(
                type: activeProfile.name,
                startedAt: startedAt,
                endedAt: now,
                realElapsed: totalElapsed,
                focusedElapsed: focusedElapsed,
                focusRatio: focusRatio,
                driftRecovered: counters.driftRecovered.value,
                awayRecovered: counters.awayRecovered.value,
                deserted: counters.deserted.value,
                timeline: timeline
            )
            lastSessionRecord = record
            saveSessionRecord(record)
        }
        saveCumulativeData()
    }

    /// プロファイル切替後、新プロファイル用にセッション状態をリセットする
    private func resetSessionForProfileSwitch() {
        let now = deps.clock.now
        focusState = .flow(since: now)
        counters = Counters()
        focusedElapsed = 0
        totalElapsed = 0
        sessionStartedAt = now
        lastTickTime = now
        timelineBlocks = []
        currentTimelinePhase = nil
        currentPhaseDuration = 0
    }

    /// プロファイル名を変更
    public func renameProfile(_ profile: SessionProfile, to newName: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx].name = newName
        if activeProfile.id == profile.id {
            activeProfile.name = newName
        }
        if persistenceEnabled { saveProfiles() }
    }

    /// プロファイルを削除（アクティブ・最後の1つは削除不可）
    public func deleteProfile(_ profile: SessionProfile) {
        guard profiles.count > 1 else { return }
        guard profile.id != activeProfile.id else { return }
        profiles.removeAll { $0.id == profile.id }
        siteObservers.removeValue(forKey: profile.id)
        profileStores.removeValue(forKey: profile.id)
        saveProfiles()
    }

    /// Ghost Teacherの回答: サイトをFLOW/DRIFTに分類
    public func classifySite(_ site: String, as classification: SiteSuggestion) {
        let previous = siteObserver.effectiveClassification(for: site)
        siteObserver.classify(site: site, as: classification)
        if pendingGhostTeacher == site {
            pendingGhostTeacher = nil
        }
        if persistenceEnabled {
            saveClassifications()
        }
        Logger.coreSession.info("""
            site classified site=\(site, privacy: .private) \
            previous=\(Self.suggestionName(previous), privacy: .public) → \
            \(Self.suggestionName(classification), privacy: .public)
            """)
    }

    private static func suggestionName(_ suggestion: SiteSuggestion) -> String {
        switch suggestion {
        case .flow:      return "flow"
        case .drift:     return "drift"
        case .undecided: return "undecided"
        }
    }

    /// アクティブプロファイルのstore
    private var activeStore: any SessionStoreProtocol {
        store(for: activeProfile)
    }

    /// テスト用: ファイルI/Oを無効化
    public var persistenceEnabled: Bool = true

    /// 今回のセッションでdismissしたサイト（次の遷移で再表示）
    private var dismissedSites: Set<String> = []

    /// Ghost Teacherを保留（次にこのサイトに戻ったら再表示）
    public func dismissGhostTeacher() {
        if let site = pendingGhostTeacher {
            dismissedSites.insert(site)
        }
        pendingGhostTeacher = nil
    }

    public var focusRatio: Double {
        guard totalElapsed > 0 else { return 0 }
        return focusedElapsed / totalElapsed
    }

    /// 現在のtimeline（確定済みブロック + 進行中ブロック）
    public var currentTimeline: [TimelineBlock] {
        var result = timelineBlocks
        if let phase = currentTimelinePhase, currentPhaseDuration > 0 {
            result.append(TimelineBlock(state: phase, duration: currentPhaseDuration))
        }
        return result
    }

    /// timelineを確定して返す（endSession時に使用）
    public func flushTimeline() -> [TimelineBlock] {
        if let phase = currentTimelinePhase, currentPhaseDuration > 0 {
            timelineBlocks.append(TimelineBlock(state: phase, duration: currentPhaseDuration))
            currentPhaseDuration = 0
            currentTimelinePhase = nil
        }
        return timelineBlocks
    }

    private func preferredBrowserSiteKey(
        browserSiteKey: String?,
        titleResolvedSite: String?
    ) -> String? {
        // ADR-0016: URLドメインが取得できれば常に優先
        if let browserSiteKey {
            return browserSiteKey
        }

        // URL取得失敗時: エイリアス経由でドメインキーに解決を試みる
        if let titleSite = titleResolvedSite,
           let domain = siteObserver.domainForAlias(titleSite) {
            return domain
        }

        return titleResolvedSite
    }

    /// 直近のセッション記録（テスト・UI用）
    @Published public private(set) var lastSessionRecord: SessionRecord?

    /// セッション記録をstoreに保存
    private func saveSessionRecord(_ record: SessionRecord) {
        guard persistenceEnabled else { return }
        let store = activeStore
        Task { try? await store.save(record) }
    }

    /// テスト用: performTickを外部から呼べるようにする
    public func performTickForTest() async {
        await performTick()
    }

    // MARK: - 永続化

    private static func defaultPersistenceRoot() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sitbone", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var profilesURL: URL {
        persistenceRoot.appendingPathComponent("profiles.json")
    }

    private var legacyCumulativeURL: URL {
        persistenceRoot.appendingPathComponent("cumulative.json")
    }

    private var profilesBaseDir: URL {
        persistenceRoot.appendingPathComponent("profiles", isDirectory: true)
    }

    private func profileDir(for profile: SessionProfile, createIfNeeded: Bool = true) -> URL {
        if createIfNeeded {
            try? FileManager.default.createDirectory(at: profilesBaseDir, withIntermediateDirectories: true)
        }

        let dir = profilesBaseDir
            .appendingPathComponent(profile.id.uuidString, isDirectory: true)
        if createIfNeeded {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func store(for profile: SessionProfile) -> any SessionStoreProtocol {
        if let cached = profileStores[profile.id] {
            return cached
        }
        guard persistenceEnabled else { return deps.store }

        let store = JSONSessionStore(baseDir: profileDir(for: profile))
        profileStores[profile.id] = store
        return store
    }

    // プロファイル一覧

    public func loadProfiles() {
        guard persistenceEnabled else { return }
        guard FileManager.default.fileExists(atPath: profilesURL.path) else {
            saveProfiles()
            return
        }
        guard let data = try? Data(contentsOf: profilesURL),
              let decoded = try? JSONDecoder().decode([SessionProfile].self, from: data),
              !decoded.isEmpty else { return }
        profiles = decoded
        activeProfile = decoded[0]
        siteObservers.removeAll()
        profileStores.removeAll()
        // 各プロファイルのSiteObserverを生成
        for profile in decoded {
            siteObservers[profile.id] = SiteObserver()
        }
        siteObserver = siteObservers[activeProfile.id] ?? SiteObserver()
        cleanupLegacyPersistenceArtifacts()
    }

    public func saveProfiles() {
        guard persistenceEnabled else { return }
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: profilesURL)
        cleanupLegacyPersistenceArtifacts()
    }

    // Ghost Teacher キーバインド

    private var keyBindingsURL: URL {
        persistenceRoot.appendingPathComponent("keybindings.json")
    }

    public func loadGhostTeacherKeyBindings() {
        guard persistenceEnabled else { return }
        guard let data = try? Data(contentsOf: keyBindingsURL),
              let decoded = try? JSONDecoder().decode(GhostTeacherKeyBindings.self, from: data)
        else { return }
        ghostTeacherKeyBindings = decoded
    }

    private func saveGhostTeacherKeyBindings() {
        guard persistenceEnabled else { return }
        guard let data = try? JSONEncoder().encode(ghostTeacherKeyBindings) else { return }
        try? data.write(to: keyBindingsURL)
    }

    // DRIFT効果音設定 (ADR-0017)

    private var driftSoundURL: URL {
        persistenceRoot.appendingPathComponent("drift-sound.json")
    }

    public func loadDriftSoundSetting() {
        guard persistenceEnabled else { return }
        guard let data = try? Data(contentsOf: driftSoundURL),
              let decoded = try? JSONDecoder().decode(DriftSoundSetting.self, from: data)
        else { return }
        driftSoundName = decoded.soundName
    }

    private func saveDriftSoundSetting() {
        guard persistenceEnabled else { return }
        let setting = DriftSoundSetting(soundName: driftSoundName)
        guard let data = try? JSONEncoder().encode(setting) else { return }
        try? data.write(to: driftSoundURL)
    }

    // プロファイル別分類

    public func loadClassifications() {
        guard persistenceEnabled else { return }
        loadClassificationsForProfile(activeProfile)
    }

    private func loadClassificationsForProfile(_ profile: SessionProfile) {
        let dir = profileDir(for: profile)
        let url = dir.appendingPathComponent("classifications.json")
        if let data = try? Data(contentsOf: url) {
            try? siteObserver.loadJSON(data)
        }
        // ADR-0016: エイリアスも読み込み + マイグレーション
        let aliasURL = dir.appendingPathComponent("aliases.json")
        if let aliasData = try? Data(contentsOf: aliasURL) {
            try? siteObserver.loadAliasesJSON(aliasData)
            // タイトル由来キーの分類をドメインキーに移行
            let migrated = siteObserver.migrateClassificationsToAliasedDomains()
            if migrated > 0 {
                saveClassificationsForActiveProfile()
            }
        }
    }

    /// 旧classifications.jsonをdefaultプロファイルにマイグレーション
    public func migrateClassifications() {
        guard persistenceEnabled else { return }
        let legacyURL = persistenceRoot.appendingPathComponent("classifications.json")
        guard let data = try? Data(contentsOf: legacyURL) else { return }
        try? siteObserver.loadJSON(data)
        saveClassificationsForActiveProfile()
        try? FileManager.default.removeItem(at: legacyURL)
    }

    /// 旧グローバルcumulative.jsonをdefaultプロファイルにマイグレーション (ADR-0012)
    public func migrateCumulativeData() {
        guard persistenceEnabled else { return }
        let legacyURL = legacyCumulativeURL
        guard FileManager.default.fileExists(atPath: legacyURL.path),
              let data = try? Data(contentsOf: legacyURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let hours = (dict["totalFocusedHours"] as? Double) ?? 0
        let driftRec = (dict["lifetimeDriftRecovered"] as? Int) ?? 0
        let awayRec = (dict["lifetimeAwayRecovered"] as? Int) ?? 0
        let deserted = (dict["lifetimeDeserted"] as? Int) ?? 0

        let legacyRecord = CumulativeRecord(
            totalFocusedHours: hours,
            lifetimeDriftRecovered: driftRec,
            lifetimeAwayRecovered: awayRec,
            lifetimeDeserted: deserted
        )

        // defaultプロファイルの既存累計にマージ
        cachedCumulative.accumulate(
            focusedHours: legacyRecord.totalFocusedHours,
            driftRecovered: legacyRecord.lifetimeDriftRecovered,
            awayRecovered: legacyRecord.lifetimeAwayRecovered,
            deserted: legacyRecord.lifetimeDeserted
        )
        cumulativeFocusedHours = cachedCumulative.totalFocusedHours

        // 保存（成功した場合のみ旧ファイル削除）
        if persistenceEnabled {
            let record = cachedCumulative
            let store = activeStore
            let url = legacyURL
            Task {
                do {
                    try await store.saveCumulative(record)
                    try? FileManager.default.removeItem(at: url)
                } catch {
                    // 保存失敗時は旧ファイルを残す
                }
            }
        }
    }

    public func saveClassifications() {
        saveClassificationsForActiveProfile()
    }

    private func saveClassificationsForActiveProfile() {
        let dir = profileDir(for: activeProfile)
        if let data = try? siteObserver.toJSON() {
            let url = dir.appendingPathComponent("classifications.json")
            try? data.write(to: url)
        }
        // ADR-0016: エイリアスも保存
        if let aliasData = try? siteObserver.aliasesToJSON() {
            let aliasURL = dir.appendingPathComponent("aliases.json")
            try? aliasData.write(to: aliasURL)
        }
    }

    /// 累積データをロード
    public func loadCumulativeData() {
        guard persistenceEnabled else { return }
        let store = activeStore
        Task {
            let record = (try? await store.loadCumulative()) ?? CumulativeRecord()
            await MainActor.run {
                self.cachedCumulative = record
                self.cumulativeFocusedHours = record.totalFocusedHours
            }
        }
    }

    /// 累積データを保存（キャッシュに加算→永続化）(ADR-0012)
    public func saveCumulativeData() {
        cachedCumulative.accumulate(
            focusedHours: focusedElapsed / 3600.0,
            driftRecovered: counters.driftRecovered.value,
            awayRecovered: counters.awayRecovered.value,
            deserted: counters.deserted.value
        )
        cumulativeFocusedHours = cachedCumulative.totalFocusedHours

        if persistenceEnabled {
            let record = cachedCumulative
            let store = activeStore
            Task { try? await store.saveCumulative(record) }
        }
    }

    private func cleanupLegacyPersistenceArtifacts() {
        let fileManager = FileManager.default
        let legacyClassificationsURL = persistenceRoot.appendingPathComponent("classifications.json")

        try? fileManager.removeItem(at: legacyClassificationsURL)
        try? fileManager.removeItem(at: legacyCumulativeURL)

        guard let profileDirs = try? fileManager.contentsOfDirectory(
            at: profilesBaseDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let validDirectoryNames = Set(profiles.map { $0.id.uuidString.lowercased() })
        for url in profileDirs {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true else {
                continue
            }

            let directoryName = url.lastPathComponent.lowercased()
            guard !validDirectoryNames.contains(directoryName) else { continue }
            try? fileManager.removeItem(at: url)
        }
    }
}
// swiftlint:enable type_body_length
