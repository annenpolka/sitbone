import Testing
import Foundation
@testable import SitboneData

struct JSONSessionStoreTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sitbone-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeSampleRecord(
        type: String = "default",
        startedAt: Date = Date(timeIntervalSince1970: 1000),
        duration: TimeInterval = 3600,
        focusedElapsed: TimeInterval = 2400
    ) -> SessionRecord {
        SessionRecord(
            type: type,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(duration),
            realElapsed: duration,
            focusedElapsed: focusedElapsed,
            focusRatio: focusedElapsed / duration,
            driftRecovered: 3,
            awayRecovered: 1,
            deserted: 0,
            timeline: [
                TimelineBlock(state: .flow, duration: 2400),
                TimelineBlock(state: .drift, duration: 600)
            ]
        )
    }

    // MARK: - Cumulative

    @Test("累計の保存と読み込みのroundtrip")
    func saveThenLoadCumulative() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = JSONSessionStore(baseDir: dir)

        let record = CumulativeRecord(
            totalFocusedHours: 42.5,
            lifetimeDriftRecovered: 10,
            lifetimeAwayRecovered: 3,
            lifetimeDeserted: 1
        )
        try await store.saveCumulative(record)
        let loaded = try await store.loadCumulative()
        #expect(loaded == record)
    }

    @Test("累計の上書き保存")
    func saveCumulativeOverwrites() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = JSONSessionStore(baseDir: dir)

        let first = CumulativeRecord(totalFocusedHours: 10.0)
        try await store.saveCumulative(first)

        let second = CumulativeRecord(totalFocusedHours: 20.0, lifetimeDriftRecovered: 5)
        try await store.saveCumulative(second)

        let loaded = try await store.loadCumulative()
        #expect(loaded == second)
    }

    @Test("ファイルなしの場合デフォルト(ゼロ)を返す")
    func loadCumulativeReturnsDefaultWhenMissing() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = JSONSessionStore(baseDir: dir)

        let loaded = try await store.loadCumulative()
        #expect(loaded == CumulativeRecord())
    }

    // MARK: - Session Records

    @Test("セッション記録の保存と読み込み")
    func saveAndLoadSession() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = JSONSessionStore(baseDir: dir)

        let record = makeSampleRecord(startedAt: Date(timeIntervalSince1970: 1_743_465_600)) // 2025-04-01
        try await store.save(record)

        let day = try await store.loadDay("2025-04-01")
        #expect(day != nil)
        #expect(day!.sessions.count == 1)
        #expect(day!.sessions[0].type == "default")
        #expect(day!.sessions[0].focusedElapsed == 2400)
        #expect(day!.sessions[0].timeline.count == 2)
    }

    @Test("同日に複数セッションを保存")
    func multipleSessionsSameDay() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = JSONSessionStore(baseDir: dir)

        let base = Date(timeIntervalSince1970: 1_743_465_600) // 2025-04-01
        let record1 = makeSampleRecord(type: "coding", startedAt: base, duration: 1800)
        let record2 = makeSampleRecord(type: "writing", startedAt: base.addingTimeInterval(3600), duration: 900)

        try await store.save(record1)
        try await store.save(record2)

        let day = try await store.loadDay("2025-04-01")
        #expect(day != nil)
        #expect(day!.sessions.count == 2)
        #expect(day!.sessions[0].type == "coding")
        #expect(day!.sessions[1].type == "writing")
    }

    @Test("存在しない日はnilを返す")
    func loadDayReturnsNilForMissingDate() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = JSONSessionStore(baseDir: dir)

        let day = try await store.loadDay("2099-12-31")
        #expect(day == nil)
    }

    @Test("Date → 日付キーの変換が正しい")
    func dateKeyFormatting() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let store = JSONSessionStore(baseDir: dir)

        // UTC 2026-04-01T10:00:00
        let date = Date(timeIntervalSince1970: 1_775_217_600)
        let record = makeSampleRecord(startedAt: date)
        try await store.save(record)

        // ローカルタイムゾーンでの日付でロードできることを確認
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        let key = formatter.string(from: date)
        let day = try await store.loadDay(key)
        #expect(day != nil)
        #expect(day!.sessions.count == 1)
    }
}
