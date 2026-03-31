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

    // MARK: - プロファイル管理 (ADR-0011)
    @Published public private(set) var activeProfile: SessionProfile
    @Published public private(set) var profiles: [SessionProfile]
    public private(set) var siteObserver: SiteObserver
    /// プロファイル別SiteObserverのキャッシュ
    private var siteObservers: [UUID: SiteObserver] = [:]

    /// FLOW→DRIFT遷移時のコールバック (ADR-0007: 効果音用)
    public var onDriftEntered: (() -> Void)?

    private let deps: Dependencies
    private let machine: FocusStateMachine
    private var tickTask: Task<Void, Never>?
    private var lastTickTime: Date?

    public init(deps: Dependencies) {
        self.deps = deps
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

        // セッション累積データを保存
        saveCumulativeData()

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
                if let site, siteObserver.isNewSite(site) {
                    pendingGhostTeacher = site
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
                if siteObserver.isNewSite(currentApp) {
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
            cumulativeFocusedHours += focusedElapsed / 3600.0
            if persistenceEnabled { saveCumulativeData() }
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
        }

        if persistenceEnabled {
            loadClassificationsForProfile(profile)
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

    /// テスト用: ファイルI/Oを無効化
    public var persistenceEnabled: Bool = true

    /// Ghost Teacherを無視
    public func dismissGhostTeacher() {
        pendingGhostTeacher = nil
    }

    public var focusRatio: Double {
        guard totalElapsed > 0 else { return 0 }
        return focusedElapsed / totalElapsed
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
            .appendingPathComponent(profile.name, isDirectory: true)
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
        // 各プロファイルのSiteObserverを生成
        for profile in decoded {
            let observer = SiteObserver()
            siteObservers[profile.id] = observer
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
        guard let data = try? Data(contentsOf: Self.cumulativeURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              let hours = dict["totalFocusedHours"] else { return }
        cumulativeFocusedHours = hours
    }

    /// 累積データを保存
    public func saveCumulativeData() {
        cumulativeFocusedHours += focusedElapsed / 3600.0
        let dict: [String: Any] = [
            "totalFocusedHours": cumulativeFocusedHours,
            "lifetimeDriftRecovered": counters.driftRecovered.value,
            "lifetimeAwayRecovered": counters.awayRecovered.value,
            "lifetimeDeserted": counters.deserted.value,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) else { return }
        try? data.write(to: Self.cumulativeURL)
    }
}
