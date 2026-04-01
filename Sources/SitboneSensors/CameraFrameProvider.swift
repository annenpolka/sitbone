// CameraFrameProvider — カメラフレーム取得のProtocol + 実装

public import CoreGraphics
import Foundation

// MARK: - Protocol

public protocol CameraFrameProviderProtocol: Sendable {
    func captureFrame() async -> CGImage?
    func stopCapture()
}

extension CameraFrameProviderProtocol {
    public func stopCapture() {}
}

// MARK: - AVCaptureSession実装 (常時稼働方式)

#if canImport(AVFoundation)
import AVFoundation
import CoreImage
import os

public final class AVCameraFrameProvider: CameraFrameProviderProtocol, @unchecked Sendable {
    private let captureQueue = DispatchQueue(label: "com.sitbone.camera.capture")
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var isConfigured = false
    private var isRunning = false

    /// フレームの鮮度TTL (3秒以上古いフレームは破棄)
    private let frameTTL: TimeInterval = 3.0
    private let lock = OSAllocatedUnfairLock<LatestFrame>(initialState: LatestFrame())

    /// 初回フレーム待ちのcontinuation
    private var startupContinuations: [CheckedContinuation<CGImage?, Never>] = []

    private var bufferDelegate: BufferDelegate?
    private let logger = Logger(subsystem: "com.sitbone", category: "sensors")

    public init() {}

    public func captureFrame() async -> CGImage? {
        guard await checkCameraAuthorization() else { return nil }

        if !isRunning { startSession() }
        guard isConfigured else { return nil }

        // キャッシュにフレッシュなフレームがあれば返す
        let cached = lock.withLock { state -> CGImage? in
            guard let image = state.image,
                  let capturedAt = state.capturedAt,
                  Date().timeIntervalSince(capturedAt) < frameTTL else {
                return nil
            }
            return image
        }
        if let cached { return cached }

        // 初回起動時またはフレーム期限切れ: 次のフレームを待つ
        return await waitForFirstFrame()
    }

    private func checkCameraAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func waitForFirstFrame() async -> CGImage? {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                // 待っている間にフレームが来たかもしれない
                let fresh = self.lock.withLock { state -> CGImage? in
                    guard let image = state.image,
                          let at = state.capturedAt,
                          Date().timeIntervalSince(at) < self.frameTTL else {
                        return nil
                    }
                    return image
                }
                if let fresh {
                    continuation.resume(returning: fresh)
                    return
                }
                let isFirst = self.startupContinuations.isEmpty
                self.startupContinuations.append(continuation)
                if isFirst {
                    self.captureQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self, !self.startupContinuations.isEmpty else { return }
                        let pending = self.startupContinuations
                        self.startupContinuations = []
                        self.logger.debug("フレーム取得タイムアウト")
                        for cont in pending {
                            cont.resume(returning: nil)
                        }
                    }
                }
            }
        }
    }

    private func startSession() {
        captureQueue.sync { [weak self] in
            guard let self, !self.isRunning else { return }

            if !isConfigured {
                configureSessionOnQueue()
            }
            guard isConfigured else { return }

            session.startRunning()
            isRunning = true
            logger.info("カメラセッション開始")
        }
    }

    private func configureSessionOnQueue() {
        session.beginConfiguration()
        session.sessionPreset = .low

        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .front
        ) ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            logger.warning("カメラデバイス初期化失敗")
            session.commitConfiguration()
            return
        }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let delegate = BufferDelegate { [weak self] cgImage in
            self?.handleFrame(cgImage)
        }
        self.bufferDelegate = delegate
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(delegate, queue: captureQueue)

        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        session.commitConfiguration()
        isConfigured = true
    }

    private func handleFrame(_ cgImage: CGImage?) {
        // 最新フレームを更新 (タイムスタンプ付き)
        if let cgImage {
            lock.withLock { state in
                state.image = cgImage
                state.capturedAt = Date()
            }
        }

        // 初回フレーム待ちのcontinuationがあれば解放
        if !startupContinuations.isEmpty {
            let pending = startupContinuations
            startupContinuations = []
            for continuation in pending {
                continuation.resume(returning: cgImage)
            }
        }
    }

    public func stopCapture() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            self.isRunning = false
            self.lock.withLock { state in
                state.image = nil
                state.capturedAt = nil
            }
            self.logger.info("カメラセッション停止")
        }
    }
}

// MARK: - 内部Delegate

private final class BufferDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let onFrame: (CGImage?) -> Void

    init(onFrame: @escaping (CGImage?) -> Void) {
        self.onFrame = onFrame
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            onFrame(nil)
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        let rect = ciImage.extent
        guard let cgImage = context.createCGImage(ciImage, from: rect) else {
            onFrame(nil)
            return
        }

        onFrame(cgImage)
    }
}

private struct LatestFrame: Sendable {
    nonisolated(unsafe) var image: CGImage?
    var capturedAt: Date?
}
#endif

// MARK: - Mock (テスト用)

public final class MockCameraFrameProvider: CameraFrameProviderProtocol, @unchecked Sendable {
    public var frame: CGImage?

    public init(frame: CGImage? = nil) {
        self.frame = frame
    }

    public func captureFrame() async -> CGImage? { frame }
}
