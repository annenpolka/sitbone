// PresenceArbiter — センサー融合 + EMA平滑化

import os
import Foundation
public import SitboneSensors

// MARK: - PresenceArbiter

public final class PresenceArbiter: PresenceDetectorProtocol, @unchecked Sendable {
    private let sensors: [any SensorProtocol]
    /// ADR-0019: present復帰のための上限閾値
    private let presentThreshold: Double
    /// ADR-0019: absent離脱のための下限閾値
    private let absentThreshold: Double
    private let emaAlpha: Double
    private let lock = OSAllocatedUnfairLock(initialState: EMAState())
    private let csvLogger: PresenceCSVLogger?
    private let enabledLock = OSAllocatedUnfairLock(initialState: true)
    private let frameProvider: (any CameraFrameProviderProtocol)?

    public var isEnabled: Bool {
        get { enabledLock.withLock { $0 } }
        set { enabledLock.withLock { $0 = newValue } }
    }

    /// 直近のdetect()で観測されたstatus (ADR-0018: 変化検知用の内部状態)
    var lastObservedStatus: PresenceStatus? {
        lock.withLock { $0.lastStatus }
    }

    public init(
        sensors: [any SensorProtocol],
        presentThreshold: Double = 0.45,
        absentThreshold: Double = 0.35,
        emaAlpha: Double = 0.3,
        frameProvider: (any CameraFrameProviderProtocol)? = nil
    ) {
        precondition(
            presentThreshold > absentThreshold,
            "presentThreshold must be greater than absentThreshold (got \(presentThreshold) vs \(absentThreshold))"
        )
        self.sensors = sensors
        self.presentThreshold = presentThreshold
        self.absentThreshold = absentThreshold
        self.emaAlpha = emaAlpha
        self.csvLogger = nil
        self.frameProvider = frameProvider
    }

    init(
        sensors: [any SensorProtocol],
        presentThreshold: Double = 0.45,
        absentThreshold: Double = 0.35,
        emaAlpha: Double = 0.3,
        csvLogger: PresenceCSVLogger?,
        frameProvider: (any CameraFrameProviderProtocol)? = nil
    ) {
        precondition(
            presentThreshold > absentThreshold,
            "presentThreshold must be greater than absentThreshold (got \(presentThreshold) vs \(absentThreshold))"
        )
        self.sensors = sensors
        self.presentThreshold = presentThreshold
        self.absentThreshold = absentThreshold
        self.emaAlpha = emaAlpha
        self.csvLogger = csvLogger
        self.frameProvider = frameProvider
    }

    /// カメラセッションを停止する
    public func stopCamera() {
        frameProvider?.stopCapture()
    }

    public func detect() async -> PresenceReading {
        guard isEnabled else {
            return PresenceReading(status: .unknown, confidence: 0)
        }

        let readings = await readAllSensors()
        let active = readings.filter { $0.reading.isPresent != nil }

        guard !active.isEmpty else {
            recordObservation(status: .unknown, emaScore: 0)
            logEntry(readings: readings, rawScore: 0, emaScore: 0, status: .unknown)
            return PresenceReading(status: .unknown, confidence: 0)
        }

        let rawScore = calculateWeightedScore(active: active)
        let smoothedScore = applyEMA(rawScore: rawScore)
        let status = applyHysteresis(smoothedScore: smoothedScore)

        Logger.sensorsPresence.debug("""
            tick raw=\(rawScore, privacy: .public) ema=\(smoothedScore, privacy: .public) \
            status=\(status.rawValue, privacy: .public)
            """)

        recordObservation(status: status, emaScore: smoothedScore)
        logEntry(readings: readings, rawScore: rawScore, emaScore: smoothedScore, status: status)

        return PresenceReading(status: status, confidence: smoothedScore)
    }

    /// 二重閾値ヒステリシスでstatusを判定する (ADR-0019)
    /// - present継続中: absentThreshold(0.35)を下回ったときだけabsentに離脱
    /// - absent/初回(nil)/unknown: presentThreshold(0.45)を超えたときだけpresentに昇格
    /// - 中間域[0.35, 0.45]では現状維持
    private func applyHysteresis(smoothedScore: Double) -> PresenceStatus {
        let previous = lock.withLock { $0.lastStatus }
        switch previous {
        case .present:
            return smoothedScore < absentThreshold ? .absent : .present
        case .absent, .unknown, .none:
            return smoothedScore >= presentThreshold ? .present : .absent
        }
    }

    /// status変化検知 + lastStatus更新 (ADR-0018)
    /// 変化があったときのみinfoログを出力する
    private func recordObservation(status: PresenceStatus, emaScore: Double) {
        let previousStatus = lock.withLock { state -> PresenceStatus? in
            let prev = state.lastStatus
            state.lastStatus = status
            return prev
        }

        if let previousStatus, previousStatus != status {
            Logger.sensorsPresence.info("""
                status \(previousStatus.rawValue, privacy: .public) → \(status.rawValue, privacy: .public) \
                ema=\(emaScore, privacy: .public)
                """)
        }
    }

    private func logEntry(
        readings: [SensorResult],
        rawScore: Double,
        emaScore: Double,
        status: PresenceStatus
    ) {
        csvLogger?.log(PresenceLogEntry(
            timestamp: Date(),
            sensorReadings: readings.map {
                SensorLogItem(
                    name: $0.weight.name,
                    isPresent: $0.reading.isPresent,
                    confidence: $0.reading.confidence
                )
            },
            rawScore: rawScore,
            emaScore: emaScore,
            status: status
        ))
    }

    // MARK: - Private

    private func readAllSensors() async -> [SensorResult] {
        await withTaskGroup(of: SensorResult.self) { group in
            for sensor in sensors {
                group.addTask {
                    SensorResult(weight: sensor.weight, reading: await sensor.read())
                }
            }
            var results: [SensorResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    private func calculateWeightedScore(active: [SensorResult]) -> Double {
        let totalWeight = active.reduce(0.0) { $0 + $1.weight.baseWeight }
        guard totalWeight > 0 else { return 0 }

        var score = 0.0
        for result in active {
            let normalizedWeight = result.weight.baseWeight / totalWeight
            let presenceValue: Double = result.reading.isPresent! ? 1.0 : 0.0
            score += normalizedWeight * presenceValue * result.reading.confidence
        }
        return score
    }

    private func applyEMA(rawScore: Double) -> Double {
        lock.withLock { state in
            let smoothed: Double
            if let previous = state.value {
                smoothed = emaAlpha * rawScore + (1 - emaAlpha) * previous
            } else {
                smoothed = rawScore
            }
            state.value = smoothed
            return smoothed
        }
    }
}

// MARK: - Internal Types

private struct EMAState: Sendable {
    var value: Double?
    var lastStatus: PresenceStatus?
}

struct SensorResult: Sendable {
    let weight: SensorWeight
    let reading: SensorReading
}
