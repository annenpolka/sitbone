import Testing
import Foundation
@testable import SitboneData

struct CumulativeRecordTests {
    @Test("デフォルトはすべてゼロ")
    func defaultIsZero() {
        let record = CumulativeRecord()
        #expect(record.totalFocusedHours == 0)
        #expect(record.lifetimeDriftRecovered == 0)
        #expect(record.lifetimeAwayRecovered == 0)
        #expect(record.lifetimeDeserted == 0)
    }

    @Test("accumulate()でセッション値が加算される")
    func accumulateAddsValues() {
        var record = CumulativeRecord(
            totalFocusedHours: 10.0,
            lifetimeDriftRecovered: 5,
            lifetimeAwayRecovered: 2,
            lifetimeDeserted: 1
        )
        record.accumulate(
            focusedHours: 1.5,
            driftRecovered: 3,
            awayRecovered: 1,
            deserted: 0
        )
        #expect(record.totalFocusedHours == 11.5)
        #expect(record.lifetimeDriftRecovered == 8)
        #expect(record.lifetimeAwayRecovered == 3)
        #expect(record.lifetimeDeserted == 1)
    }

    @Test("accumulate()を複数回呼んでも正しく累積する")
    func accumulateMultipleTimes() {
        var record = CumulativeRecord()
        record.accumulate(focusedHours: 1.0, driftRecovered: 2, awayRecovered: 1, deserted: 0)
        record.accumulate(focusedHours: 0.5, driftRecovered: 1, awayRecovered: 0, deserted: 1)
        #expect(record.totalFocusedHours == 1.5)
        #expect(record.lifetimeDriftRecovered == 3)
        #expect(record.lifetimeAwayRecovered == 1)
        #expect(record.lifetimeDeserted == 1)
    }

    @Test("Codable roundtrip")
    func codableRoundTrip() throws {
        let original = CumulativeRecord(
            totalFocusedHours: 42.5,
            lifetimeDriftRecovered: 100,
            lifetimeAwayRecovered: 30,
            lifetimeDeserted: 5
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CumulativeRecord.self, from: data)
        #expect(decoded == original)
    }
}
