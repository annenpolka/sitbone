import XCTest
@testable import SitboneUI
@testable import SitboneData

final class SitboneUITests: XCTestCase {

    func testMenuBarIconReturnsImage() {
        let flowIcon = menuBarIcon(phase: .flow)
        XCTAssertEqual(flowIcon.size.width, 18)

        let nilIcon = menuBarIcon(phase: nil)
        XCTAssertEqual(nilIcon.size.width, 18)
    }
}
