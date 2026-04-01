import Testing
import Foundation
@testable import SitboneCore

struct ProfilePersistenceRegressionTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sitbone-core-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(value)
        try data.write(to: url)
    }

    @Test("persistenceEnabled=false のとき profiles.json を書かない")
    @MainActor
    func persistenceDisabledSkipsProfileWrites() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let engine = SessionEngine(deps: .test(), persistenceRoot: dir)
        engine.persistenceEnabled = false
        _ = engine.createProfile(name: "coding")

        let profilesURL = dir.appendingPathComponent("profiles.json")
        #expect(!FileManager.default.fileExists(atPath: profilesURL.path))
    }

    @Test("プロファイル別の分類が再起動後も独立して残る")
    @MainActor
    func perProfileClassificationsPersistAcrossRestart() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let engine1 = SessionEngine(deps: .test(), persistenceRoot: dir)
        let coding = engine1.createProfile(name: "coding")

        engine1.classifySite("YouTube", as: .drift)
        engine1.switchProfile(to: coding)
        engine1.classifySite("YouTube", as: .flow)

        let engine2 = SessionEngine(deps: .test(), persistenceRoot: dir)
        engine2.loadProfiles()
        engine2.loadClassifications()

        #expect(engine2.activeProfile.name == "default")
        #expect(engine2.siteObserver.classification(for: "YouTube") == .drift)

        let restoredCoding = try #require(engine2.profiles.first { $0.name == "coding" })
        engine2.switchProfile(to: restoredCoding)
        #expect(engine2.siteObserver.classification(for: "YouTube") == .flow)
    }

    @Test("profiles.json がなくても default プロファイルが次回起動で復元される")
    @MainActor
    func defaultProfilePersistsAcrossRestartWithoutPreexistingProfilesFile() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let engine1 = SessionEngine(deps: .test(), persistenceRoot: dir)
        engine1.loadProfiles()
        let originalDefaultID = engine1.activeProfile.id
        engine1.classifySite("YouTube", as: .drift)

        let engine2 = SessionEngine(deps: .test(), persistenceRoot: dir)
        engine2.loadProfiles()
        engine2.loadClassifications()

        #expect(engine2.activeProfile.id == originalDefaultID)
        #expect(engine2.activeProfile.name == "default")
        #expect(engine2.siteObserver.classification(for: "YouTube") == .drift)
    }

    @Test("loadProfiles() で古い名前ベースと孤児ディレクトリを掃除する")
    @MainActor
    func loadProfilesCleansLegacyAndOrphanedDirectories() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let currentProfile = SessionProfile(name: "default")
        try write([currentProfile], to: dir.appendingPathComponent("profiles.json"))

        let profilesDir = dir.appendingPathComponent("profiles", isDirectory: true)
        let legacyDir = profilesDir.appendingPathComponent("default", isDirectory: true)
        let orphanDir = profilesDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let currentDir = profilesDir.appendingPathComponent(currentProfile.id.uuidString, isDirectory: true)

        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentDir, withIntermediateDirectories: true)

        let engine = SessionEngine(deps: .test(), persistenceRoot: dir)
        engine.loadProfiles()

        #expect(FileManager.default.fileExists(atPath: currentDir.path))
        #expect(!FileManager.default.fileExists(atPath: legacyDir.path))
        #expect(!FileManager.default.fileExists(atPath: orphanDir.path))
    }

    @Test("初期化だけでは空のプロファイルディレクトリを作らない")
    @MainActor
    func initDoesNotCreateProfileDirectories() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        _ = SessionEngine(deps: .test(), persistenceRoot: dir)

        let profilesDir = dir.appendingPathComponent("profiles", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: profilesDir.path))
    }
}
