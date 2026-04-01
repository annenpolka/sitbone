import Testing
import SwiftUI
@testable import SitboneUI
@testable import SitboneData

struct UILogicTests {

    // MARK: - formatTime

    @Test("formatTime: 秒のみ")
    func formatTimeSecondsOnly() {
        #expect(formatTime(45) == "0:45")
    }

    @Test("formatTime: 分と秒")
    func formatTimeMinutesAndSeconds() {
        #expect(formatTime(125) == "2:05")
    }

    @Test("formatTime: 時分秒")
    func formatTimeHoursMinutesSeconds() {
        #expect(formatTime(3661) == "1:01:01")
    }

    @Test("formatTime: ゼロ")
    func formatTimeZero() {
        #expect(formatTime(0) == "0:00")
    }

    // MARK: - formatCompactTime

    @Test("formatCompactTime: 秒のみ")
    func formatCompactTimeSeconds() {
        #expect(formatCompactTime(45) == "0:45")
    }

    @Test("formatCompactTime: 時分秒")
    func formatCompactTimeHours() {
        #expect(formatCompactTime(7261) == "2:01:01")
    }

    // MARK: - formatCumulativeHours

    @Test("formatCumulativeHours: 1時間以上")
    func formatCumulativeAboveOneHour() {
        #expect(formatCumulativeHours(2.5) == "2.5h")
    }

    @Test("formatCumulativeHours: 1時間未満は分表示")
    func formatCumulativeBelowOneHour() {
        #expect(formatCumulativeHours(0.5) == "30m")
    }

    @Test("formatCumulativeHours: ゼロ")
    func formatCumulativeZero() {
        #expect(formatCumulativeHours(0) == "0m")
    }

    @Test("formatCumulativeHours: ちょうど1時間")
    func formatCumulativeExactlyOne() {
        #expect(formatCumulativeHours(1.0) == "1.0h")
    }

    // MARK: - FocusPhase.label

    @Test("FocusPhase.label")
    func focusPhaseLabels() {
        #expect(FocusPhase.flow.label == "FLOW")
        #expect(FocusPhase.drift.label == "DRIFT")
        #expect(FocusPhase.away.label == "AWAY")
    }

    // MARK: - FocusPhase.color

    @Test("FocusPhase.colorはnilでない")
    func focusPhaseColorsExist() {
        // Color同士の直接比較は困難だが、クラッシュしないことを確認
        _ = FocusPhase.flow.color
        _ = FocusPhase.drift.color
        _ = FocusPhase.away.color
    }

    // MARK: - profilePhaseColor

    @Test("profilePhaseColor: FLOWは明るい色")
    func profilePhaseColorFlow() {
        let color = profilePhaseColor(phase: .flow, hue: 0.5)
        // Color(hue: 0.5, saturation: 0.7, brightness: 0.9)
        #expect(color == Color(hue: 0.5, saturation: 0.7, brightness: 0.9))
    }

    @Test("profilePhaseColor: DRIFTは暗い色")
    func profilePhaseColorDrift() {
        let color = profilePhaseColor(phase: .drift, hue: 0.3)
        #expect(color == Color(hue: 0.3, saturation: 0.5, brightness: 0.5))
    }

    @Test("profilePhaseColor: AWAYはgray")
    func profilePhaseColorAway() {
        #expect(profilePhaseColor(phase: .away, hue: 0.5) == .gray)
    }

    @Test("profilePhaseColor: nilはgray")
    func profilePhaseColorNil() {
        #expect(profilePhaseColor(phase: nil, hue: 0.5) == .gray)
    }

    // MARK: - ghostPanelFrame

    @Test("ghostPanelFrame: 画面中央に配置")
    func ghostPanelFrameCenter() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let frame = ghostPanelFrame(screenFrame: screen, safeTop: 38)
        #expect(frame.width == 280)
        #expect(frame.height == 64)
        // 中央揃え: x = 1920/2 - 280/2 = 820
        #expect(frame.origin.x == 820)
        // 上端: 1080 - 38 - 64 - 6 = 972
        #expect(frame.origin.y == 972)
    }

    @Test("ghostPanelFrame: 外部ディスプレイでも正しい位置")
    func ghostPanelFrameExternalDisplay() {
        let screen = CGRect(x: -1920, y: 0, width: 1920, height: 1200)
        let frame = ghostPanelFrame(screenFrame: screen, safeTop: 24)
        let expectedX: CGFloat = -1920 + 1920/2 - 280/2
        let expectedY: CGFloat = 1200 - 24 - 64 - 6
        #expect(frame.origin.x == expectedX)
        #expect(frame.origin.y == expectedY)
    }
}
