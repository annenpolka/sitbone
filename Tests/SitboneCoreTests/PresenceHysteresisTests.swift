// PresenceHysteresisTests — ADR-0019: 二重閾値ヒステリシス検証
//
// PresenceArbiterの present/absent 判定が、単一閾値ではなく
// presentThreshold(0.45) / absentThreshold(0.35) の二重閾値で動作することを検証する。

import Testing
@testable import SitboneCore
@testable import SitboneSensors

struct PresenceHysteresisTests {

    /// confidence値で正規化スコアを直接コントロールするヘルパー
    /// 単一センサー (weight=1.0) なので score = isPresent ? confidence : 0
    /// alpha=1.0と組み合わせると ema = score になり、テストで任意のema値を作れる
    private static func makeScoreSensor(score: Double) -> MockSensor {
        MockSensor(
            name: "camera", baseWeight: 1.0,
            reading: SensorReading(isPresent: true, confidence: score)
        )
    }

    @Test("present維持: 中間域 (ema=0.40) は present のまま")
    func presentStaysInMiddleBand() async {
        let sensor = Self.makeScoreSensor(score: 0.50)
        let arbiter = PresenceArbiter(sensors: [sensor], emaAlpha: 1.0)

        // 初回: 0.50 >= 0.45 → present
        _ = await arbiter.detect()
        #expect(arbiter.lastObservedStatus == .present)

        // 中間域へ: ema=0.40 (0.35 < 0.40 < 0.45)
        sensor.reading = SensorReading(isPresent: true, confidence: 0.40)
        let result = await arbiter.detect()
        #expect(result.status == .present)
        #expect(arbiter.lastObservedStatus == .present)
    }

    @Test("absent維持: 中間域 (ema=0.40) は absent のまま")
    func absentStaysInMiddleBand() async {
        let sensor = Self.makeScoreSensor(score: 0.20)
        let arbiter = PresenceArbiter(sensors: [sensor], emaAlpha: 1.0)

        // 初回: 0.20 < 0.45 → absent
        _ = await arbiter.detect()
        #expect(arbiter.lastObservedStatus == .absent)

        // 中間域へ: ema=0.40
        sensor.reading = SensorReading(isPresent: true, confidence: 0.40)
        let result = await arbiter.detect()
        #expect(result.status == .absent)
        #expect(arbiter.lastObservedStatus == .absent)
    }

    @Test("present→absent: ema が 0.35 を下回ると離脱")
    func presentExitsBelowAbsentThreshold() async {
        let sensor = Self.makeScoreSensor(score: 0.50)
        let arbiter = PresenceArbiter(sensors: [sensor], emaAlpha: 1.0)

        _ = await arbiter.detect()
        #expect(arbiter.lastObservedStatus == .present)

        // ema=0.34 (< 0.35)
        sensor.reading = SensorReading(isPresent: true, confidence: 0.34)
        let result = await arbiter.detect()
        #expect(result.status == .absent)
    }

    @Test("absent→present: ema が 0.45 を超えると復帰")
    func absentEntersAbovePresentThreshold() async {
        let sensor = Self.makeScoreSensor(score: 0.20)
        let arbiter = PresenceArbiter(sensors: [sensor], emaAlpha: 1.0)

        _ = await arbiter.detect()
        #expect(arbiter.lastObservedStatus == .absent)

        // ema=0.46 (>= 0.45)
        sensor.reading = SensorReading(isPresent: true, confidence: 0.46)
        let result = await arbiter.detect()
        #expect(result.status == .present)
    }

    @Test("初回判定 (lastStatus=nil) は presentThreshold 基準で保守的")
    func firstDetectIsConservative() async {
        // 中間域: 0.40 → 初回はlastStatus=nilなのでpresentThreshold基準で判定
        let middle = Self.makeScoreSensor(score: 0.40)
        let arbiterMid = PresenceArbiter(sensors: [middle], emaAlpha: 1.0)
        let resultMid = await arbiterMid.detect()
        #expect(resultMid.status == .absent, "0.40 < presentThreshold(0.45) → absent")

        // 上限超え: 0.50
        let above = Self.makeScoreSensor(score: 0.50)
        let arbiterAbove = PresenceArbiter(sensors: [above], emaAlpha: 1.0)
        let resultAbove = await arbiterAbove.detect()
        #expect(resultAbove.status == .present, "0.50 >= presentThreshold(0.45) → present")

        // 下限割れ: 0.20
        let below = Self.makeScoreSensor(score: 0.20)
        let arbiterBelow = PresenceArbiter(sensors: [below], emaAlpha: 1.0)
        let resultBelow = await arbiterBelow.detect()
        #expect(resultBelow.status == .absent, "0.20 < presentThreshold(0.45) → absent")
    }

    @Test("実観測の振動シナリオ (0.422→0.399→0.430→0.300) が status flip を起こさない")
    func observedOscillationIsAbsorbed() async {
        // ADR-0019 Context: 単一閾値方式では4回 flip した連続値
        let sensor = Self.makeScoreSensor(score: 0.422)
        let arbiter = PresenceArbiter(sensors: [sensor], emaAlpha: 1.0)

        // 初回 0.422 < 0.45 → absent
        var result = await arbiter.detect()
        #expect(result.status == .absent)

        // 0.399 (中間域) → absent維持
        sensor.reading = SensorReading(isPresent: true, confidence: 0.399)
        result = await arbiter.detect()
        #expect(result.status == .absent)

        // 0.430 (中間域、まだpresent閾値未満) → absent維持
        sensor.reading = SensorReading(isPresent: true, confidence: 0.430)
        result = await arbiter.detect()
        #expect(result.status == .absent)

        // 0.300 < 0.35 → absent (もともとabsentなのでflipなし)
        sensor.reading = SensorReading(isPresent: true, confidence: 0.300)
        result = await arbiter.detect()
        #expect(result.status == .absent)
    }
}
