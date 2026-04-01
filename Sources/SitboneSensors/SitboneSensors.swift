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
    func frontmostWindowURL() -> String?
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
    private let chromeScriptableBrowsers: Set<String> = [
        "Google Chrome", "Arc", "Brave Browser", "Microsoft Edge",
        "Opera", "Vivaldi", "Chromium"
    ]

    public init() {}

    public func frontmostAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    public func frontmostWindowTitle() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let focusedWindow = copyFocusedWindow(from: axApp) else { return nil }
        var titleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(focusedWindow, kAXTitleAttribute as CFString, &titleValue)
        return titleValue as? String
    }

    public func frontmostWindowURL() -> String? {
        guard let appName = frontmostAppName() else { return nil }

        switch appName {
        case "Safari":
            return runAppleScript("""
                tell application "Safari"
                    if not (exists front document) then return ""
                    return URL of front document
                end tell
                """
            )

        case let name where chromeScriptableBrowsers.contains(name):
            return runAppleScript("""
                tell application "\(name)"
                    if not (exists front window) then return ""
                    return URL of active tab of front window
                end tell
                """
            )

        default:
            return nil
        }
    }

    private func runAppleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }

        let value = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func copyFocusedWindow(from application: AXUIElement) -> AXUIElement? {
        var focusedWindowValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )
        guard error == .success, let focusedWindowValue else {
            return nil
        }
        guard CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(focusedWindowValue, to: AXUIElement.self)
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
    public var urlString: String?

    public func frontmostAppName() -> String? { appName }
    public func frontmostWindowTitle() -> String? { windowTitle }
    public func frontmostWindowURL() -> String? { urlString }
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

public final class MockSensor: SensorProtocol, @unchecked Sendable {
    public let weight: SensorWeight
    public var reading: SensorReading

    public init(name: String, baseWeight: Double, reading: SensorReading) {
        self.weight = SensorWeight(name: name, baseWeight: baseWeight)
        self.reading = reading
    }

    public func read() async -> SensorReading { reading }
}
