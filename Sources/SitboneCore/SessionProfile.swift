// SessionProfile — セッションプロファイル（アプリ分類 + 閾値のセット）
// ADR-0011

public import Foundation

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
        case flowThreshold = "t1"
        case awayThreshold = "t2"
        case flowRecovery
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            driftDelay: try container.decode(TimeInterval.self, forKey: .flowThreshold),
            awayDelay: try container.decode(TimeInterval.self, forKey: .awayThreshold),
            flowRecovery: try container.decode(TimeInterval.self, forKey: .flowRecovery)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(driftDelay, forKey: .flowThreshold)
        try container.encode(awayDelay, forKey: .awayThreshold)
        try container.encode(flowRecovery, forKey: .flowRecovery)
    }
}
