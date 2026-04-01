// PresenceArbiter — センサー融合 + EMA平滑化

import os
import Foundation
public import SitboneSensors

// MARK: - PresenceArbiter

public final class PresenceArbiter: PresenceDetectorProtocol, @unchecked Sendable {
    private let sensors: [any SensorProtocol]
    private let threshold: Double
    private let emaAlpha: Double
    private let lock = OSAllocatedUnfairLock(initialState: EMAState())
    private let csvLogger: PresenceCSVLogger?
    private let enabledLock = OSAllocatedUnfairLock(initialState: true)

    public var isEnabled: Bool {
        get { enabledLock.withLock { $0 } }
        set { enabledLock.withLock { $0 = newValue } }
    }

    public init(
        sensors: [any SensorProtocol],
        threshold: Double = 0.4,
        emaAlpha: Double = 0.3
    ) {
        self.sensors = sensors
        self.threshold = threshold
        self.emaAlpha = emaAlpha
        self.csvLogger = nil
    }

    init(
        sensors: [any SensorProtocol],
        threshold: Double = 0.4,
        emaAlpha: Double = 0.3,
        csvLogger: PresenceCSVLogger?
    ) {
        self.sensors = sensors
        self.threshold = threshold
        self.emaAlpha = emaAlpha
        self.csvLogger = csvLogger
    }

    public func detect() async -> PresenceReading {
        guard isEnabled else {
            return PresenceReading(status: .unknown, confidence: 0)
        }

        let readings = await readAllSensors()
        let active = readings.filter { $0.reading.isPresent != nil }

        guard !active.isEmpty else {
            logEntry(readings: readings, rawScore: 0, emaScore: 0, status: .unknown)
            return PresenceReading(status: .unknown, confidence: 0)
        }

        let rawScore = calculateWeightedScore(active: active)
        let smoothedScore = applyEMA(rawScore: rawScore)
        let status: PresenceStatus = smoothedScore >= threshold ? .present : .absent

        logEntry(readings: readings, rawScore: rawScore, emaScore: smoothedScore, status: status)

        return PresenceReading(status: status, confidence: smoothedScore)
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
}

struct SensorResult: Sendable {
    let weight: SensorWeight
    let reading: SensorReading
}
