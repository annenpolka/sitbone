// SensorReading — 個別センサーの読み取り値と重み

// MARK: - SensorWeight

public struct SensorWeight: Sendable, Equatable {
    public let name: String
    public let baseWeight: Double

    public init(name: String, baseWeight: Double) {
        self.name = name
        self.baseWeight = baseWeight
    }
}

// MARK: - SensorReading

public struct SensorReading: Sendable, Equatable {
    /// nil = センサー利用不可/失敗
    public let isPresent: Bool?
    /// 0.0-1.0 の信頼度
    public let confidence: Double

    public init(isPresent: Bool?, confidence: Double = 1.0) {
        self.isPresent = isPresent
        self.confidence = confidence
    }

    public static let unavailable = SensorReading(isPresent: nil, confidence: 0)
}

// MARK: - SensorProtocol

public protocol SensorProtocol: Sendable {
    var weight: SensorWeight { get }
    func read() async -> SensorReading
}
