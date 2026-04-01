// JSONSessionStore — ファイルベースのSessionStoreProtocol実装

public import Foundation

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
        let data = try encoder.encode(record)
        try data.write(to: cumulativeURL, options: .atomic)
    }

    public func loadCumulative() async throws -> CumulativeRecord {
        guard FileManager.default.fileExists(atPath: cumulativeURL.path) else {
            return CumulativeRecord()
        }
        let data = try Data(contentsOf: cumulativeURL)
        return try decoder.decode(CumulativeRecord.self, from: data)
    }

    // MARK: - Sessions

    public func save(_ record: SessionRecord) async throws {
        let key = dateFormatter.string(from: record.startedAt)
        let url = sessionsDir.appendingPathComponent("\(key).json")

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
    }

    public func loadDay(_ date: String) async throws -> DayRecord? {
        let url = sessionsDir.appendingPathComponent("\(date).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(DayRecord.self, from: data)
    }
}
