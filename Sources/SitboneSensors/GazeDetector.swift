// GazeDetector — 顔の正面性 + 瞳孔位置による視線推定

import Vision

// MARK: - GazeClassifier (純粋関数: テスト可能)

/// 顔の向き(yaw/pitch)と瞳孔位置から、画面を見ているかを判定する
public enum GazeClassifier {
    /// yaw/pitchの閾値 (ラジアン, ≈17度)
    static let orientationThreshold: Double = 0.3

    /// 分類結果
    public struct Result: Sendable {
        public let isPresent: Bool
        public let confidence: Double
    }

    /// - Parameters:
    ///   - yaw: 顔の水平回転 (-1.0〜1.0, 0が正面)
    ///   - pitch: 顔の垂直回転 (-1.0〜1.0, 0が正面)
    ///   - leftPupilX: 左目の瞳孔X位置 (0.0〜1.0, 0.5が中央), nil=データなし
    ///   - rightPupilX: 右目の瞳孔X位置 (0.0〜1.0, 0.5が中央), nil=データなし
    public static func classify(
        yaw: Double,
        pitch: Double,
        leftPupilX: Double?,
        rightPupilX: Double?
    ) -> Result {
        let absYaw = abs(yaw)
        let absPitch = abs(pitch)

        // 閾値超過 → absent
        guard absYaw <= orientationThreshold,
              absPitch <= orientationThreshold else {
            return Result(isPresent: false, confidence: 0.0)
        }

        // 正面性スコア: 0→1.0 (正面), 0.3→0.0 (境界)
        let yawScore = 1.0 - (absYaw / orientationThreshold)
        let pitchScore = 1.0 - (absPitch / orientationThreshold)
        let orientationConfidence = yawScore * pitchScore

        // 瞳孔スコア: 中央(0.5)からのずれ
        let pupilConfidence: Double
        if let leftX = leftPupilX, let rightX = rightPupilX {
            let leftDeviation = abs(leftX - 0.5) * 2.0   // 0.0〜1.0
            let rightDeviation = abs(rightX - 0.5) * 2.0
            let avgDeviation = (leftDeviation + rightDeviation) / 2.0
            pupilConfidence = max(0.0, 1.0 - avgDeviation)
        } else {
            // 瞳孔データなし → 確証が弱いのでconfidenceを下げる
            pupilConfidence = 0.5
        }

        // 総合confidence: 正面性70% + 瞳孔30%
        let confidence = orientationConfidence * 0.7 + pupilConfidence * 0.3

        return Result(isPresent: true, confidence: confidence)
    }
}

// MARK: - GazeDetector (Vision連携)

public final class GazeDetector: SensorProtocol, @unchecked Sendable {
    public let weight: SensorWeight
    private let frameProvider: any CameraFrameProviderProtocol

    public init(
        frameProvider: any CameraFrameProviderProtocol,
        baseWeight: Double = 0.50
    ) {
        self.weight = SensorWeight(name: "gaze", baseWeight: baseWeight)
        self.frameProvider = frameProvider
    }

    public func read() async -> SensorReading {
        guard let frame = await frameProvider.captureFrame() else {
            return .unavailable
        }

        return await classifyFromFrame(frame)
    }

    private func classifyFromFrame(_ image: CGImage) async -> SensorReading {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return .unavailable
        }

        guard let face = request.results?.first else {
            return SensorReading(isPresent: false, confidence: 1.0)
        }

        // yaw/pitchが取得できない場合は判定不能
        guard let yawNumber = face.yaw, let pitchNumber = face.pitch else {
            return .unavailable
        }
        let yaw = yawNumber.doubleValue
        let pitch = pitchNumber.doubleValue

        // 瞳孔位置の抽出
        let leftPupilX = extractPupilX(from: face.landmarks?.leftPupil)
        let rightPupilX = extractPupilX(from: face.landmarks?.rightPupil)

        let classification = GazeClassifier.classify(
            yaw: yaw, pitch: pitch,
            leftPupilX: leftPupilX, rightPupilX: rightPupilX
        )

        return SensorReading(
            isPresent: classification.isPresent,
            confidence: classification.confidence
        )
    }

    private func extractPupilX(
        from region: VNFaceLandmarkRegion2D?
    ) -> Double? {
        guard let region, let point = region.normalizedPoints.first else {
            return nil
        }
        return Double(point.x)
    }
}
