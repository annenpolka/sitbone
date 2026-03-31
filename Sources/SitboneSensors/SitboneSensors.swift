// SitboneSensors — センサーProtocol + 実装

public import Foundation
import CoreGraphics

// MARK: - Presence Reading

public enum PresenceStatus: String, Sendable {
    case present
    case absent
    case unknown
}

public struct PresenceReading: Sendable {
    public let status: PresenceStatus
    public let confidence: Double

    public init(status: PresenceStatus, confidence: Double = 1.0) {
        self.status = status
        self.confidence = confidence
    }
}

// MARK: - Protocols

public protocol ClockProtocol: Sendable {
    var now: Date { get }
}

public protocol WindowMonitorProtocol: Sendable {
    func frontmostAppName() -> String?
    func frontmostWindowTitle() -> String?
}

public protocol IdleDetectorProtocol: Sendable {
    func secondsSinceLastEvent() -> Double
}

public protocol PresenceDetectorProtocol: Sendable {
    func detect() async -> PresenceReading
}

// MARK: - SystemClock

public struct SystemClock: ClockProtocol, Sendable {
    public var now: Date { Date() }
    public init() {}
}

// MARK: - FixedClock (テスト用)

public final class FixedClock: ClockProtocol, @unchecked Sendable {
    public var now: Date

    public init(_ date: Date = Date()) {
        self.now = date
    }

    public func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

// MARK: - CGEventSource Idle Detector

public struct CGEventSourceIdleDetector: IdleDetectorProtocol, Sendable {
    public init() {}

    public func secondsSinceLastEvent() -> Double {
        // kCGAnyInputEventType = ~0
        let anyInputEventType = CGEventType(rawValue: UInt32.max)!
        return CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyInputEventType
        )
    }
}

// MARK: - NSWorkspace Window Monitor

#if canImport(AppKit)
import AppKit

public struct NSWorkspaceWindowMonitor: WindowMonitorProtocol, Sendable {
    public init() {}

    public func frontmostAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    public func frontmostWindowTitle() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value)
        guard err == .success, let window = value else { return nil }
        var title: AnyObject?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        return title as? String
    }
}
#endif

// MARK: - Mock implementations (テスト用)

public final class MockWindowMonitor: WindowMonitorProtocol, @unchecked Sendable {
    public var appName: String?

    public init(appName: String? = "Xcode") {
        self.appName = appName
    }

    public var windowTitle: String?

    public func frontmostAppName() -> String? { appName }
    public func frontmostWindowTitle() -> String? { windowTitle }
}

public final class MockIdleDetector: IdleDetectorProtocol, @unchecked Sendable {
    public var idle: Double

    public init(idle: Double = 0) {
        self.idle = idle
    }

    public func secondsSinceLastEvent() -> Double { idle }
}

public struct MockPresenceDetector: PresenceDetectorProtocol, Sendable {
    public let reading: PresenceReading

    public init(status: PresenceStatus = .present) {
        self.reading = PresenceReading(status: status)
    }

    public func detect() async -> PresenceReading { reading }
}
