import XCTest
@testable import SitboneCore
@testable import SitboneData

final class SiteObserverPersistenceTests: XCTestCase {

    func testExportImportClassifications() {
        let observer = SiteObserver()
        observer.classify(site: "YouTube", as: .drift)
        observer.classify(site: "GitHub", as: .flow)
        observer.record(site: "YouTube", phase: .drift, duration: 100)

        let data = observer.exportClassifications()
        XCTAssertEqual(data.count, 2)
        XCTAssertEqual(data["YouTube"], "drift")
        XCTAssertEqual(data["GitHub"], "flow")
    }

    func testImportClassifications() {
        let observer = SiteObserver()
        let data: [String: String] = ["Twitter": "drift", "VS Code": "flow"]
        observer.importClassifications(data)

        XCTAssertEqual(observer.classification(for: "Twitter"), .drift)
        XCTAssertEqual(observer.classification(for: "VS Code"), .flow)
        XCTAssertFalse(observer.isNewSite("Twitter"))
    }

    func testJsonRoundTrip() throws {
        let observer = SiteObserver()
        observer.classify(site: "YouTube", as: .drift)
        observer.classify(site: "docs.rs", as: .flow)

        let json = try observer.toJSON()
        XCTAssertFalse(json.isEmpty)

        let restored = SiteObserver()
        try restored.loadJSON(json)
        XCTAssertEqual(restored.classification(for: "YouTube"), .drift)
        XCTAssertEqual(restored.classification(for: "docs.rs"), .flow)
    }
}
