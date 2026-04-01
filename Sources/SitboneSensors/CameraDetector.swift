// CameraDetector — Vision顔検出によるpresence判定

import Vision

public final class CameraDetector: SensorProtocol, @unchecked Sendable {
    public let weight: SensorWeight
    private let frameProvider: any CameraFrameProviderProtocol

    public init(
        frameProvider: any CameraFrameProviderProtocol,
        baseWeight: Double = 0.35
    ) {
        self.weight = SensorWeight(name: "camera", baseWeight: baseWeight)
        self.frameProvider = frameProvider
    }

    public func read() async -> SensorReading {
        guard let frame = await frameProvider.captureFrame() else {
            return .unavailable
        }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: frame, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return .unavailable
        }

        guard let face = request.results?.first else {
            return SensorReading(isPresent: false, confidence: 1.0)
        }

        return SensorReading(
            isPresent: true,
            confidence: Double(face.confidence)
        )
    }
}
