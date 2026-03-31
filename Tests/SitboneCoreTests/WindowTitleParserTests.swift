import XCTest
@testable import SitboneCore

final class WindowTitleParserTests: XCTestCase {

    // MARK: - ブラウザタイトルからサイト名抽出

    func testChromeTitle() {
        let result = WindowTitleParser.extractSiteName(
            from: "GitHub - annenpolka/sitbone · Pull Request #3 - Google Chrome",
            app: "Google Chrome"
        )
        XCTAssertEqual(result, "GitHub")
    }

    func testFirefoxTitle() {
        let result = WindowTitleParser.extractSiteName(
            from: "docs.rs - rand - Rust - Firefox",
            app: "Firefox"
        )
        XCTAssertEqual(result, "docs.rs")
    }

    func testSafariTitle() {
        let result = WindowTitleParser.extractSiteName(
            from: "Stack Overflow - Where Developers Learn - Safari",
            app: "Safari"
        )
        XCTAssertEqual(result, "Stack Overflow")
    }

    func testBrowserWithSimpleTitle() {
        let result = WindowTitleParser.extractSiteName(
            from: "Twitter - Google Chrome",
            app: "Google Chrome"
        )
        XCTAssertEqual(result, "Twitter")
    }

    func testNonBrowserReturnsNil() {
        let result = WindowTitleParser.extractSiteName(
            from: "SitboneCore.swift",
            app: "VS Code"
        )
        XCTAssertNil(result)
    }

    func testArcBrowser() {
        let result = WindowTitleParser.extractSiteName(
            from: "YouTube - Arc",
            app: "Arc"
        )
        XCTAssertEqual(result, "YouTube")
    }

    // MARK: - ブラウザ判定

    func testIsBrowser() {
        XCTAssertTrue(WindowTitleParser.isBrowser("Google Chrome"))
        XCTAssertTrue(WindowTitleParser.isBrowser("Firefox"))
        XCTAssertTrue(WindowTitleParser.isBrowser("Safari"))
        XCTAssertTrue(WindowTitleParser.isBrowser("Arc"))
        XCTAssertFalse(WindowTitleParser.isBrowser("VS Code"))
        XCTAssertFalse(WindowTitleParser.isBrowser("Terminal"))
    }
}
