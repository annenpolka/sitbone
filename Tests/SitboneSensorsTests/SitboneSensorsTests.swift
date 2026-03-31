import XCTest
@testable import SitboneSensors

final class SitboneSensorsTests: XCTestCase {

    func testFixedClockAdvance() {
        let date = Date(timeIntervalSince1970: 1000)
        let clock = FixedClock(date)
        clock.advance(by: 60)
        XCTAssertEqual(clock.now.timeIntervalSince1970, 1060)
    }

    func testMockIdleDetector() {
        let idle = MockIdleDetector(idle: 42.5)
        XCTAssertEqual(idle.secondsSinceLastEvent(), 42.5)
    }

    func testMockPresenceDetector() async {
        let detector = MockPresenceDetector(status: .absent)
        let reading = await detector.detect()
        XCTAssertEqual(reading.status, .absent)
    }
}
