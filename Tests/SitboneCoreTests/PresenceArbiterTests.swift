import Testing
@testable import SitboneCore
@testable import SitboneSensors

struct PresenceArbiterTests {

    // MARK: - 融合ロジック

    struct FusionLogic {
        @Test("カメラpresent + gazepresent → 総合present")
        func bothPresentResultsInPresent() async {
            let camera = MockSensor(
                name: "camera", baseWeight: 0.50,
                reading: SensorReading(isPresent: true)
            )
            let gaze = MockSensor(
                name: "gaze", baseWeight: 0.20,
                reading: SensorReading(isPresent: true)
            )
            let arbiter = PresenceArbiter(sensors: [camera, gaze])
            let result = await arbiter.detect()
            #expect(result.status == .present)
        }

        @Test("カメラabsent + gazeabsent → 総合absent")
        func bothAbsentResultsInAbsent() async {
            let camera = MockSensor(
                name: "camera", baseWeight: 0.50,
                reading: SensorReading(isPresent: false)
            )
            let gaze = MockSensor(
                name: "gaze", baseWeight: 0.20,
                reading: SensorReading(isPresent: false)
            )
            let arbiter = PresenceArbiter(sensors: [camera, gaze])
            let result = await arbiter.detect()
            #expect(result.status == .absent)
        }

        @Test("カメラpresent + gazeabsent → 総合present（正規化0.714 > 0.4）")
        func cameraPresentGazeAbsentIsPresent() async {
            let camera = MockSensor(
                name: "camera", baseWeight: 0.50,
                reading: SensorReading(isPresent: true)
            )
            let gaze = MockSensor(
                name: "gaze", baseWeight: 0.20,
                reading: SensorReading(isPresent: false)
            )
            let arbiter = PresenceArbiter(sensors: [camera, gaze])
            let result = await arbiter.detect()
            #expect(result.status == .present)
        }

        @Test("カメラabsent + gazepresent → 総合absent（正規化0.286 < 0.4）")
        func cameraAbsentGazePresentIsAbsent() async {
            let camera = MockSensor(
                name: "camera", baseWeight: 0.50,
                reading: SensorReading(isPresent: false)
            )
            let gaze = MockSensor(
                name: "gaze", baseWeight: 0.20,
                reading: SensorReading(isPresent: true)
            )
            let arbiter = PresenceArbiter(sensors: [camera, gaze])
            let result = await arbiter.detect()
            #expect(result.status == .absent)
        }
    }

    // MARK: - 重み正規化

    struct WeightNormalization {
        @Test("カメラのみ有効時、重みが1.0に正規化される")
        func singleSensorNormalization() async {
            let camera = MockSensor(
                name: "camera", baseWeight: 0.50,
                reading: SensorReading(isPresent: true)
            )
            let gaze = MockSensor(
                name: "gaze", baseWeight: 0.20,
                reading: .unavailable
            )
            let arbiter = PresenceArbiter(sensors: [camera, gaze])
            let result = await arbiter.detect()
            #expect(result.status == .present)
            // confidence should reflect the normalized score (1.0 for single present sensor)
            #expect(result.confidence > 0.9)
        }

        @Test("全センサー無効 → unknown")
        func allSensorsUnavailableReturnsUnknown() async {
            let camera = MockSensor(
                name: "camera", baseWeight: 0.50,
                reading: .unavailable
            )
            let gaze = MockSensor(
                name: "gaze", baseWeight: 0.20,
                reading: .unavailable
            )
            let arbiter = PresenceArbiter(sensors: [camera, gaze])
            let result = await arbiter.detect()
            #expect(result.status == .unknown)
        }

        @Test("センサーなし → unknown")
        func noSensorsReturnsUnknown() async {
            let arbiter = PresenceArbiter(sensors: [])
            let result = await arbiter.detect()
            #expect(result.status == .unknown)
        }
    }

    // MARK: - EMA平滑化

    struct EMASmoothing {
        @Test("初回読み取りはEMAなし（raw scoreがそのまま使われる）")
        func firstReadingNoSmoothing() async {
            let camera = MockSensor(
                name: "camera", baseWeight: 0.50,
                reading: SensorReading(isPresent: true)
            )
            let gaze = MockSensor(
                name: "gaze", baseWeight: 0.20,
                reading: SensorReading(isPresent: true)
            )
            let arbiter = PresenceArbiter(sensors: [camera, gaze])
            let result = await arbiter.detect()
            // raw score = 1.0, no EMA applied
            #expect(result.confidence >= 0.99)
        }

        @Test("一瞬のabsentでpresentが維持される（EMAが0.4以上）")
        func momentaryAbsentDoesNotFlip() async {
            let camera = MockSensor(
                name: "camera", baseWeight: 0.50,
                reading: SensorReading(isPresent: true)
            )
            let gaze = MockSensor(
                name: "gaze", baseWeight: 0.20,
                reading: SensorReading(isPresent: true)
            )
            let arbiter = PresenceArbiter(sensors: [camera, gaze])

            // 最初の読み取り: 全present → EMA = 1.0
            _ = await arbiter.detect()

            // 一瞬absent
            camera.reading = SensorReading(isPresent: false)
            gaze.reading = SensorReading(isPresent: false)
            let afterBlip = await arbiter.detect()

            // EMA = 0.3 * 0.0 + 0.7 * 1.0 = 0.7 → still present
            #expect(afterBlip.status == .present)
        }

        @Test("連続absentでEMAが閾値を下回る")
        func sustainedAbsentDropsBelowThreshold() async {
            let camera = MockSensor(
                name: "camera", baseWeight: 0.50,
                reading: SensorReading(isPresent: true)
            )
            let gaze = MockSensor(
                name: "gaze", baseWeight: 0.20,
                reading: SensorReading(isPresent: true)
            )
            let arbiter = PresenceArbiter(sensors: [camera, gaze])

            // 初回: present → EMA = 1.0
            _ = await arbiter.detect()

            // absent連続
            camera.reading = SensorReading(isPresent: false)
            gaze.reading = SensorReading(isPresent: false)

            // EMA推移: 1.0 → 0.7 → 0.49 → 0.343
            // 3回目で0.4を下回る
            _ = await arbiter.detect()  // 0.7
            _ = await arbiter.detect()  // 0.49
            let result = await arbiter.detect()  // 0.343
            #expect(result.status == .absent)
        }

        @Test("alpha=1.0でEMAが即座に追従する")
        func alphaOneNoSmoothing() async {
            let camera = MockSensor(
                name: "camera", baseWeight: 0.50,
                reading: SensorReading(isPresent: true)
            )
            let arbiter = PresenceArbiter(
                sensors: [camera],
                emaAlpha: 1.0
            )

            _ = await arbiter.detect()  // present, EMA = 1.0

            camera.reading = SensorReading(isPresent: false)
            let result = await arbiter.detect()  // alpha=1.0: EMA = 0.0 immediately
            #expect(result.status == .absent)
        }
    }

    // MARK: - Confidence加重

    struct ConfidenceWeighting {
        @Test("低confidenceのpresent読み取りはスコアを下げる")
        func lowConfidenceReducesScore() async {
            let camera = MockSensor(
                name: "camera", baseWeight: 0.50,
                reading: SensorReading(isPresent: true, confidence: 0.3)
            )
            let gaze = MockSensor(
                name: "gaze", baseWeight: 0.20,
                reading: SensorReading(isPresent: false)
            )
            // score = 0.714 * 1.0 * 0.3 + 0.286 * 0.0 = 0.214 < 0.4
            let arbiter = PresenceArbiter(sensors: [camera, gaze])
            let result = await arbiter.detect()
            #expect(result.status == .absent)
        }
    }

    // MARK: - Protocol適合

    struct ProtocolConformance {
        @Test("PresenceDetectorProtocolとして使用可能")
        func conformsToPresenceDetectorProtocol() async {
            let camera = MockSensor(
                name: "camera", baseWeight: 0.50,
                reading: SensorReading(isPresent: true)
            )
            let arbiter = PresenceArbiter(sensors: [camera])
            let detector: any PresenceDetectorProtocol = arbiter
            let result = await detector.detect()
            #expect(result.status == .present)
        }
    }

    // MARK: - status変化検知 (ADR-0018)

    struct StatusChangeTracking {
        @Test("初回detect前はlastObservedStatusがnil")
        func initialLastStatusIsNil() {
            let arbiter = PresenceArbiter(sensors: [])
            #expect(arbiter.lastObservedStatus == nil)
        }

        @Test("初回detect後にlastObservedStatusが記録される")
        func firstDetectRecordsStatus() async {
            let camera = MockSensor(
                name: "camera", baseWeight: 0.50,
                reading: SensorReading(isPresent: true)
            )
            let arbiter = PresenceArbiter(sensors: [camera])
            _ = await arbiter.detect()
            #expect(arbiter.lastObservedStatus == .present)
        }

        @Test("present→absentに変化するとlastObservedStatusが更新される")
        func statusFlipsFromPresentToAbsent() async {
            let camera = MockSensor(
                name: "camera", baseWeight: 0.50,
                reading: SensorReading(isPresent: true)
            )
            // alpha=1.0でEMA平滑化を無効化し、即座にabsentに切り替わるようにする
            let arbiter = PresenceArbiter(sensors: [camera], emaAlpha: 1.0)

            _ = await arbiter.detect()
            #expect(arbiter.lastObservedStatus == .present)

            camera.reading = SensorReading(isPresent: false)
            _ = await arbiter.detect()
            #expect(arbiter.lastObservedStatus == .absent)
        }

        @Test("センサーが空のときdetectすればlastObservedStatusはunknownになる")
        func emptySensorsRecordUnknown() async {
            let arbiter = PresenceArbiter(sensors: [])
            _ = await arbiter.detect()
            #expect(arbiter.lastObservedStatus == .unknown)
        }
    }
}
