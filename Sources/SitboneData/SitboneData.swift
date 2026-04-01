// SitboneData — データ型定義・永続化

public import Foundation

// MARK: - Counter（不正状態が構成不可能）

public struct Counter: Sendable, Codable, Equatable {
    public private(set) var value: Int = 0
    public mutating func increment() { value += 1 }
    public init() {}
}

// MARK: - FocusPhase

public enum FocusPhase: String, Sendable, Codable {
    case flow
    case drift
    case away
}

// MARK: - Timeline

public struct TimelineBlock: Codable, Sendable, Equatable {
    public let state: FocusPhase
    public let duration: TimeInterval

    public init(state: FocusPhase, duration: TimeInterval) {
        self.state = state
        self.duration = duration
    }
}

// MARK: - Session

public struct SessionRecord: Codable, Sendable {
    public let type: String
    public let startedAt: Date
    public let endedAt: Date
    public let realElapsed: TimeInterval
    public let focusedElapsed: TimeInterval
    public let focusRatio: Double
    public let driftRecovered: Int
    public let awayRecovered: Int
    public let deserted: Int
    public let timeline: [TimelineBlock]

    public init(
        type: String, startedAt: Date, endedAt: Date,
        realElapsed: TimeInterval, focusedElapsed: TimeInterval,
        focusRatio: Double, driftRecovered: Int,
        awayRecovered: Int, deserted: Int,
        timeline: [TimelineBlock]
    ) {
        self.type = type
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.realElapsed = realElapsed
        self.focusedElapsed = focusedElapsed
        self.focusRatio = focusRatio
        self.driftRecovered = driftRecovered
        self.awayRecovered = awayRecovered
        self.deserted = deserted
        self.timeline = timeline
    }
}

// MARK: - Day / Cumulative

public struct DayRecord: Codable, Sendable {
    public let date: String
    public var sessions: [SessionRecord]

    public init(date: String, sessions: [SessionRecord] = []) {
        self.date = date
        self.sessions = sessions
    }
}

public struct CumulativeRecord: Codable, Sendable, Equatable {
    public var totalFocusedHours: Double
    public var lifetimeDriftRecovered: Int
    public var lifetimeAwayRecovered: Int
    public var lifetimeDeserted: Int

    public init(
        totalFocusedHours: Double = 0,
        lifetimeDriftRecovered: Int = 0,
        lifetimeAwayRecovered: Int = 0,
        lifetimeDeserted: Int = 0
    ) {
        self.totalFocusedHours = totalFocusedHours
        self.lifetimeDriftRecovered = lifetimeDriftRecovered
        self.lifetimeAwayRecovered = lifetimeAwayRecovered
        self.lifetimeDeserted = lifetimeDeserted
    }

    /// セッション結果を累計に加算する
    public mutating func accumulate(
        focusedHours: Double,
        driftRecovered: Int,
        awayRecovered: Int,
        deserted: Int
    ) {
        totalFocusedHours += focusedHours
        lifetimeDriftRecovered += driftRecovered
        lifetimeAwayRecovered += awayRecovered
        lifetimeDeserted += deserted
    }
}

// MARK: - Store Protocol

public protocol SessionStoreProtocol: Sendable {
    func save(_ record: SessionRecord) async throws
    func loadDay(_ date: String) async throws -> DayRecord?
    func loadCumulative() async throws -> CumulativeRecord
    func saveCumulative(_ record: CumulativeRecord) async throws
}

// MARK: - InMemorySessionStore (テスト用)

public final class InMemorySessionStore: SessionStoreProtocol, @unchecked Sendable {
    private var days: [String: DayRecord] = [:]
    private var cumulative = CumulativeRecord()

    public init() {}

    public func save(_ record: SessionRecord) async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let key = formatter.string(from: record.startedAt)
        if days[key] != nil {
            days[key]!.sessions.append(record)
        } else {
            days[key] = DayRecord(date: key, sessions: [record])
        }
    }

    public func loadDay(_ date: String) async throws -> DayRecord? {
        days[date]
    }

    public func loadCumulative() async throws -> CumulativeRecord {
        cumulative
    }

    public func saveCumulative(_ record: CumulativeRecord) async throws {
        cumulative = record
    }
}
