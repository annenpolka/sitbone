// SessionProfile — セッションプロファイル（アプリ分類 + 閾値のセット）
// ADR-0011

public import Foundation
public import SitboneData

public struct SessionProfile: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public var colorHue: Double      // 0.0-1.0
    public var thresholds: Thresholds

    public init(
        name: String,
        colorHue: Double = 0.45,  // デフォルト: mint
        thresholds: Thresholds = Thresholds()
    ) {
        self.id = UUID()
        self.name = name
        self.colorHue = colorHue
        self.thresholds = thresholds
    }

    /// デフォルトプロファイル（初回起動時に自動生成）
    public static func makeDefault() -> SessionProfile {
        SessionProfile(name: "default", colorHue: 0.45)
    }

    public static func == (lhs: SessionProfile, rhs: SessionProfile) -> Bool {
        lhs.id == rhs.id
    }
}

// ThresholdsをCodableに
extension Thresholds: Codable {
    enum CodingKeys: String, CodingKey {
        case t1, t2, flowRecovery
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            t1: try c.decode(TimeInterval.self, forKey: .t1),
            t2: try c.decode(TimeInterval.self, forKey: .t2),
            flowRecovery: try c.decode(TimeInterval.self, forKey: .flowRecovery)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(t1, forKey: .t1)
        try c.encode(t2, forKey: .t2)
        try c.encode(flowRecovery, forKey: .flowRecovery)
    }
}
