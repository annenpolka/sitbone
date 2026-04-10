// JSONSessionStore — ファイルベースのSessionStoreProtocol実装

public import Foundation
import os

public final class JSONSessionStore: SessionStoreProtocol, @unchecked Sendable {
    private let baseDir: URL
    private let sessionsDir: URL
    private let cumulativeURL: URL

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    public init(baseDir: URL) {
        self.baseDir = baseDir
        self.sessionsDir = baseDir.appendingPathComponent("sessions", isDirectory: true)
        self.cumulativeURL = baseDir.appendingPathComponent("cumulative.json")
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    }

    // MARK: - Cumulative

    public func saveCumulative(_ record: CumulativeRecord) async throws {
        do {
            let data = try encoder.encode(record)
            try data.write(to: cumulativeURL, options: .atomic)
        } catch {
            Logger.dataStore.error("""
                cumulative save failed path=\(self.cumulativeURL.path, privacy: .private) \
                error=\(error.localizedDescription, privacy: .public)
                """)
            throw error
        }
    }

    public func loadCumulative() async throws -> CumulativeRecord {
        guard FileManager.default.fileExists(atPath: cumulativeURL.path) else {
            return CumulativeRecord()
        }
        do {
            let data = try Data(contentsOf: cumulativeURL)
            return try decoder.decode(CumulativeRecord.self, from: data)
        } catch {
            Logger.dataStore.error("""
                cumulative load failed path=\(self.cumulativeURL.path, privacy: .private) \
                error=\(error.localizedDescription, privacy: .public)
                """)
            throw error
        }
    }

    // MARK: - Sessions

    public func save(_ record: SessionRecord) async throws {
        let key = dateFormatter.string(from: record.startedAt)
        let url = sessionsDir.appendingPathComponent("\(key).json")

        do {
            var day: DayRecord
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                day = try decoder.decode(DayRecord.self, from: data)
                day.sessions.append(record)
            } else {
                day = DayRecord(date: key, sessions: [record])
            }

            let data = try encoder.encode(day)
            try data.write(to: url, options: .atomic)

            Logger.dataStore.info("""
                session saved key=\(key, privacy: .public) \
                sessionsInDay=\(day.sessions.count, privacy: .public) \
                path=\(url.path, privacy: .private)
                """)
        } catch {
            Logger.dataStore.error("""
                session save failed key=\(key, privacy: .public) \
                path=\(url.path, privacy: .private) \
                error=\(error.localizedDescription, privacy: .public)
                """)
            throw error
        }
    }

    public func loadDay(_ date: String) async throws -> DayRecord? {
        let url = sessionsDir.appendingPathComponent("\(date).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(DayRecord.self, from: data)
        } catch {
            Logger.dataStore.error("""
                day load failed date=\(date, privacy: .public) \
                path=\(url.path, privacy: .private) \
                error=\(error.localizedDescription, privacy: .public)
                """)
            throw error
        }
    }
}
