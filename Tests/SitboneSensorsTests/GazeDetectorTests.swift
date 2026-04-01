import Testing
@testable import SitboneSensors

struct GazeClassificationTests {

    // MARK: - 正面性判定

    struct Frontality {
        @Test("yaw=0, pitch=0 → 正面向き → present")
        func directlyFacingIsPresent() {
            let result = GazeClassifier.classify(
                yaw: 0.0, pitch: 0.0,
                leftPupilX: 0.5, rightPupilX: 0.5
            )
            #expect(result.isPresent == true)
            #expect(result.confidence > 0.8)
        }

        @Test("yaw=0.1, pitch=-0.05 → ほぼ正面 → present")
        func slightlyOffCenterIsPresent() {
            let result = GazeClassifier.classify(
                yaw: 0.1, pitch: -0.05,
                leftPupilX: 0.5, rightPupilX: 0.5
            )
            #expect(result.isPresent == true)
        }

        @Test("|yaw| > 0.3 → 横向き → absent")
        func sidewaysFaceIsAbsent() {
            let result = GazeClassifier.classify(
                yaw: 0.4, pitch: 0.0,
                leftPupilX: 0.5, rightPupilX: 0.5
            )
            #expect(result.isPresent == false)
        }

        @Test("|pitch| > 0.3 → 上/下向き → absent")
        func lookingUpIsAbsent() {
            let result = GazeClassifier.classify(
                yaw: 0.0, pitch: 0.4,
                leftPupilX: 0.5, rightPupilX: 0.5
            )
            #expect(result.isPresent == false)
        }

        @Test("yaw=-0.3 境界値 → present")
        func yawBoundaryPresent() {
            let result = GazeClassifier.classify(
                yaw: -0.3, pitch: 0.0,
                leftPupilX: 0.5, rightPupilX: 0.5
            )
            #expect(result.isPresent == true)
        }

        @Test("yaw=-0.31 境界値超過 → absent")
        func yawBoundaryAbsent() {
            let result = GazeClassifier.classify(
                yaw: -0.31, pitch: 0.0,
                leftPupilX: 0.5, rightPupilX: 0.5
            )
            #expect(result.isPresent == false)
        }
    }

    // MARK: - 瞳孔位置

    struct PupilPosition {
        @Test("瞳孔が端に寄っている → confidenceが下がる")
        func offCenterPupilsReduceConfidence() {
            let centered = GazeClassifier.classify(
                yaw: 0.0, pitch: 0.0,
                leftPupilX: 0.5, rightPupilX: 0.5
            )
            let offCenter = GazeClassifier.classify(
                yaw: 0.0, pitch: 0.0,
                leftPupilX: 0.2, rightPupilX: 0.2
            )
            #expect(offCenter.confidence < centered.confidence)
        }

        @Test("瞳孔データなし → 正面性のみで判定")
        func noPupilDataUsesOrientationOnly() {
            let result = GazeClassifier.classify(
                yaw: 0.0, pitch: 0.0,
                leftPupilX: nil, rightPupilX: nil
            )
            #expect(result.isPresent == true)
        }
    }

    // MARK: - Confidence計算

    struct ConfidenceCalculation {
        @Test("完全正面 + 瞳孔中央 → confidence ≈ 1.0")
        func perfectAlignmentMaxConfidence() {
            let result = GazeClassifier.classify(
                yaw: 0.0, pitch: 0.0,
                leftPupilX: 0.5, rightPupilX: 0.5
            )
            #expect(result.confidence >= 0.95)
        }

        @Test("境界付近 → confidence低め")
        func nearBoundaryLowerConfidence() {
            let result = GazeClassifier.classify(
                yaw: 0.25, pitch: 0.25,
                leftPupilX: 0.5, rightPupilX: 0.5
            )
            #expect(result.isPresent == true)
            #expect(result.confidence < 0.7)
        }
    }
}
