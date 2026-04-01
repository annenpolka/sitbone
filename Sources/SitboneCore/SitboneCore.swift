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

    /// FLOW→DRIFT遷移時のコールバック (ADR-0007: 効果音用)
    public var onDriftEntered: (() -> Void)?

    private let deps: Dependencies
    private let machine: FocusStateMachine
    private var tickTask: Task<Void, Never>?
    private var lastTickTime: Date?

    // MARK: - Timeline tracking (ADR-0012)
    private var timelineBlocks: [TimelineBlock] = []
    private var currentTimelinePhase: FocusPhase?
    private var currentPhaseDuration: TimeInterval = 0

    public init(deps: Dependencies) {
        self.deps = deps
        let defaultProfile = SessionProfile.makeDefault()
        self.activeProfile = defaultProfile
        self.profiles = [defaultProfile]
        let observer = SiteObserver()
        self.siteObserver = observer
        self.siteObservers[defaultProfile.id] = observer
        self.machine = FocusStateMachine(deps: deps)
        // デフォルトプロファイルにディスクバックドストアを即時作成
        if persistenceEnabled {
            profileStores[defaultProfile.id] = JSONSessionStore(baseDir: profileDir(for: defaultProfile))
        }
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

        // セッション累積データを保存
        saveCumulativeData()

        focusState = nil
        lastTickTime = nil
    }

    private func performTick() async {
        guard let state = focusState else { return }
        let now = deps.clock.now
        let oldPhase = state.phase

        let delta: TimeInterval
        if let last = lastTickTime {
            delta = now.timeIntervalSince(last)
            totalElapsed += delta
            if oldPhase == .flow {
                focusedElapsed += delta
            }
        } else {
            delta = 0
        }

        // Timeline tracking (ADR-0012)
        if currentTimelinePhase == oldPhase {
            currentPhaseDuration += delta
        } else {
            if let prevPhase = currentTimelinePhase, currentPhaseDuration > 0 {
                timelineBlocks.append(TimelineBlock(state: prevPhase, duration: currentPhaseDuration))
            }
            currentTimelinePhase = oldPhase
            currentPhaseDuration = delta
        }

        lastTickTime = now

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

        // Ghost Teacher + SiteResolver (ADR-0009, ADR-0010)
        let prevApp = currentApp
        currentApp = deps.windowMonitor.frontmostAppName() ?? ""
        currentWindowTitle = deps.windowMonitor.frontmostWindowTitle() ?? ""

        if WindowTitleParser.isBrowser(currentApp) {
            // ブラウザ: SiteResolverでサイト名を安定抽出
            let resolution = SiteResolver.resolve(
                title: currentWindowTitle, app: currentApp, observer: siteObserver
            )
            let site = resolution.site
            if currentSite != site {
                currentSite = site
                if let site {
                    // 再訪: dismissedから外す
                    dismissedSites.remove(site)
                    if siteObserver.isUnclassified(site) && !dismissedSites.contains(site) {
                        pendingGhostTeacher = site
                    }
                }
            }
            if let site {
                siteObserver.record(site: site, phase: newPhase, duration: 1)
            }
            // ブラウザアプリ自体のGhost Teacherは抑制
        } else {
            currentSite = nil
            // 非ブラウザアプリ: アプリ単位でGhost Teacher
            if currentApp != prevApp && !currentApp.isEmpty {
                dismissedSites.remove(currentApp)
                if siteObserver.isUnclassified(currentApp) && !dismissedSites.contains(currentApp) {
                    pendingGhostTeacher = currentApp
                }
            }
            if !currentApp.isEmpty {
                siteObserver.record(site: currentApp, phase: newPhase, duration: 1)
            }
        }

        // FLOW→DRIFT遷移を検出してコールバック (ADR-0007)
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
        if persistenceEnabled {
            profileStores[profile.id] = JSONSessionStore(baseDir: profileDir(for: profile))
        }
        saveProfiles()
        return profile
    }

    /// プロファイルを切替（セッション分割）
    public func switchProfile(to profile: SessionProfile) {
        guard profiles.contains(where: { $0.id == profile.id }) else { return }

        if persistenceEnabled {
            saveClassificationsForActiveProfile()
        }

        if isSessionActive {
            // セッション分割: 現プロファイルの累計に加算 + SessionRecord保存
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

        // プロファイル切替: SiteObserverを差し替え
        activeProfile = profile
        let newObserver = siteObservers[profile.id] ?? SiteObserver()
        siteObserver = newObserver
        if siteObservers[profile.id] == nil {
            siteObservers[profile.id] = newObserver
        }

        // セッションリセット
        if isSessionActive {
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

        // 新プロファイルの累計をロード（クロス汚染防止）
        cachedCumulative = CumulativeRecord()
        cumulativeFocusedHours = 0
        if persistenceEnabled {
            loadClassificationsForProfile(profile)
            loadCumulativeData()
        }
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
        saveProfiles()
    }

    /// Ghost Teacherの回答: サイトをFLOW/DRIFTに分類
    public func classifySite(_ site: String, as classification: SiteSuggestion) {
        siteObserver.classify(site: site, as: classification)
        if pendingGhostTeacher == site {
            pendingGhostTeacher = nil
        }
        if persistenceEnabled {
            saveClassifications()
        }
    }

    /// アクティブプロファイルのstore
    private var activeStore: any SessionStoreProtocol {
        profileStores[activeProfile.id] ?? deps.store
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

    private static let sitboneDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sitbone", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let profilesURL: URL = {
        sitboneDir.appendingPathComponent("profiles.json")
    }()

    private static let cumulativeURL: URL = {
        sitboneDir.appendingPathComponent("cumulative.json")
    }()

    private func profileDir(for profile: SessionProfile) -> URL {
        let dir = Self.sitboneDir
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(profile.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // プロファイル一覧

    public func loadProfiles() {
        guard let data = try? Data(contentsOf: Self.profilesURL),
              let decoded = try? JSONDecoder().decode([SessionProfile].self, from: data),
              !decoded.isEmpty else { return }
        profiles = decoded
        activeProfile = decoded[0]
        // 各プロファイルのSiteObserver + SessionStoreを生成
        for profile in decoded {
            let observer = SiteObserver()
            siteObservers[profile.id] = observer
            profileStores[profile.id] = JSONSessionStore(baseDir: profileDir(for: profile))
        }
        siteObserver = siteObservers[activeProfile.id] ?? SiteObserver()
    }

    public func saveProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: Self.profilesURL)
    }

    // プロファイル別分類

    public func loadClassifications() {
        loadClassificationsForProfile(activeProfile)
    }

    private func loadClassificationsForProfile(_ profile: SessionProfile) {
        let url = profileDir(for: profile).appendingPathComponent("classifications.json")
        guard let data = try? Data(contentsOf: url) else { return }
        try? siteObserver.loadJSON(data)
    }

    /// 旧classifications.jsonをdefaultプロファイルにマイグレーション
    public func migrateClassifications() {
        let legacyURL = Self.sitboneDir.appendingPathComponent("classifications.json")
        guard let data = try? Data(contentsOf: legacyURL) else { return }
        try? siteObserver.loadJSON(data)
        saveClassificationsForActiveProfile()
        try? FileManager.default.removeItem(at: legacyURL)
    }

    /// 旧グローバルcumulative.jsonをdefaultプロファイルにマイグレーション (ADR-0012)
    public func migrateCumulativeData() {
        let legacyURL = Self.cumulativeURL
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
        guard let data = try? siteObserver.toJSON() else { return }
        let url = profileDir(for: activeProfile).appendingPathComponent("classifications.json")
        try? data.write(to: url)
    }

    /// 累積データをロード
    public func loadCumulativeData() {
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
}
