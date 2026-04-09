import Testing
import Foundation
@testable import SitboneCore
@testable import SitboneSensors
@testable import SitboneData

struct DriftSoundTests {
    @MainActor
    private func makeEngine() -> SessionEngine {
        let deps = Dependencies(
            clock: FixedClock(),
            windowMonitor: MockWindowMonitor(),
            idleDetector: MockIdleDetector(idle: 0),
            presenceDetector: MockPresenceDetector(status: .absent),
            store: InMemorySessionStore()
        )
        let engine = SessionEngine(deps: deps)
        engine.persistenceEnabled = false
        return engine
    }

    @Test("デフォルトのDRIFT効果音はTink")
    @MainActor
    func defaultSoundIsTink() {
        let engine = makeEngine()
        #expect(engine.driftSoundName == "Tink")
    }

    @Test("DRIFT効果音をnilにすると無効化される")
    @MainActor
    func disableSound() {
        let engine = makeEngine()
        engine.driftSoundName = nil
        #expect(engine.driftSoundName == nil)
    }

    @Test("DRIFT効果音を別のサウンドに変更できる")
    @MainActor
    func changeSound() {
        let engine = makeEngine()
        engine.driftSoundName = "Glass"
        #expect(engine.driftSoundName == "Glass")
    }

    @Test("DRIFT効果音の永続化: 保存と読み込み")
    @MainActor
    func persistDriftSound() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sitbone-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 保存
        let deps = Dependencies(
            clock: FixedClock(),
            windowMonitor: MockWindowMonitor(),
            idleDetector: MockIdleDetector(idle: 0),
            presenceDetector: MockPresenceDetector(status: .absent),
            store: InMemorySessionStore()
        )
        let engine1 = SessionEngine(deps: deps, persistenceRoot: tmpDir)
        engine1.driftSoundName = "Glass"

        // 別インスタンスで読み込み
        let engine2 = SessionEngine(deps: deps, persistenceRoot: tmpDir)
        engine2.loadDriftSoundSetting()
        #expect(engine2.driftSoundName == "Glass")
    }

    @Test("DRIFT効果音をnilで永続化するとnilで復元される")
    @MainActor
    func persistNilSound() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sitbone-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let deps = Dependencies(
            clock: FixedClock(),
            windowMonitor: MockWindowMonitor(),
            idleDetector: MockIdleDetector(idle: 0),
            presenceDetector: MockPresenceDetector(status: .absent),
            store: InMemorySessionStore()
        )
        let engine1 = SessionEngine(deps: deps, persistenceRoot: tmpDir)
        engine1.driftSoundName = nil

        let engine2 = SessionEngine(deps: deps, persistenceRoot: tmpDir)
        engine2.loadDriftSoundSetting()
        #expect(engine2.driftSoundName == nil)
    }
}
