// PresenceCSVLogger — センサー融合結果のCSV + os.Logger出力

import os
import Foundation
import SitboneSensors

// MARK: - PresenceLogEntry

struct PresenceLogEntry: Sendable {
    let timestamp: Date
    let sensorReadings: [SensorLogItem]
    let rawScore: Double
    let emaScore: Double
    let status: PresenceStatus
}

struct SensorLogItem: Sendable {
    let name: String
    let isPresent: Bool?
    let confidence: Double
}

// MARK: - PresenceCSVLogger

final class PresenceCSVLogger: @unchecked Sendable {
    private let fileHandle: FileHandle?
    private let lock = OSAllocatedUnfairLock<Void>(initialState: ())
    private let osLogger = Logger(subsystem: "com.sitbone", category: "presence")
    private let dateFormatter: ISO8601DateFormatter

    init(directory: URL? = nil) {
        dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        guard let directory else {
            fileHandle = nil
            return
        }

        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        let fileName = "presence_\(timestamp).csv"
        let fileURL = directory.appendingPathComponent(fileName)

        fileManager.createFile(atPath: fileURL.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: fileURL)

        // ヘッダー書き込み
        let fields = ["timestamp", "camera_present", "camera_confidence",
                      "gaze_present", "gaze_confidence", "raw_score", "ema_score", "status"]
        let header = fields.joined(separator: ",") + "\n"
        fileHandle?.write(Data(header.utf8))

        osLogger.info("CSV logging started: \(fileURL.path)")
    }

    func log(_ entry: PresenceLogEntry) {
        // os.Logger出力
        let sensorSummary = entry.sensorReadings
            .map { item in
                let present = item.isPresent.map { String($0) } ?? "N/A"
                return "\(item.name)=\(present)(\(String(format: "%.2f", item.confidence)))"
            }
            .joined(separator: " ")
        let raw = String(format: "%.3f", entry.rawScore)
        let ema = String(format: "%.3f", entry.emaScore)

        osLogger.debug("presence: \(sensorSummary) raw=\(raw) ema=\(ema) → \(entry.status.rawValue)")

        // CSV出力
        guard let fileHandle else { return }

        let cameraSensor = entry.sensorReadings.first { $0.name == "camera" }
        let gazeSensor = entry.sensorReadings.first { $0.name == "gaze" }

        let row = [
            dateFormatter.string(from: entry.timestamp),
            cameraSensor?.isPresent.map { String($0) } ?? "",
            cameraSensor.map { String(format: "%.3f", $0.confidence) } ?? "",
            gazeSensor?.isPresent.map { String($0) } ?? "",
            gazeSensor.map { String(format: "%.3f", $0.confidence) } ?? "",
            String(format: "%.3f", entry.rawScore),
            String(format: "%.3f", entry.emaScore),
            entry.status.rawValue
        ].joined(separator: ",") + "\n"

        lock.withLock {
            fileHandle.write(Data(row.utf8))
        }
    }

    deinit {
        try? fileHandle?.close()
    }
}
