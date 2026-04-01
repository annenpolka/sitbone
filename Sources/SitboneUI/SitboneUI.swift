// SitboneUI — メニューバーUI

public import SwiftUI
public import SitboneCore
public import SitboneData

// MARK: - フォーカス状態の色（Color定義はNotchOverlay.swiftに集約）

extension FocusPhase {
    public var color: Color {
        switch self {
        case .flow: .sitboneFlow
        case .drift: .sitboneDrift
        case .away: .sitboneAway
        }
    }

    public var label: String {
        switch self {
        case .flow: "FLOW"
        case .drift: "DRIFT"
        case .away: "AWAY"
        }
    }
}

// MARK: - MenuBarView

public struct MenuBarView: View {
    @ObservedObject var engine: SessionEngine

    public init(engine: SessionEngine) {
        self.engine = engine
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

            if engine.isSessionActive {
                activeSessionView
            } else {
                inactiveView
            }

            Divider()
            profileSection
            Divider()
            sessionToggle
            Divider()

            Button("Quit Sitbone") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(8)
        .frame(width: 260)
    }

    private var header: some View {
        HStack {
            Text("Sitbone")
                .font(.headline)
            Spacer()
            if let phase = engine.focusState?.phase {
                Text(phase.label)
                    .font(.caption.bold())
                    .foregroundStyle(phase.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(phase.color.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
    }

    private var activeSessionView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Honest Clock
            HStack {
                VStack(alignment: .leading) {
                    Text("Focused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatTime(engine.focusedElapsed))
                        .font(.system(.title2, design: .monospaced))
                        .foregroundStyle(Color.sitboneFlow)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Elapsed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatTime(engine.totalElapsed))
                        .font(.system(.title2, design: .monospaced))
                        .foregroundStyle(.primary)
                }
            }

            // Focus Ratio バー
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.sitboneFlow)
                        .frame(width: geo.size.width * engine.focusRatio)
                }
            }
            .frame(height: 6)

            HStack {
                Text("Ratio: \(Int(engine.focusRatio * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            // カウンタ
            HStack(spacing: 16) {
                counterItem("↩", engine.counters.driftRecovered.value, Color.sitboneFlow)
                counterItem("←", engine.counters.awayRecovered.value, Color.sitboneAccent)
                counterItem("✕", engine.counters.deserted.value, Color.sitboneAway)
            }

            // 現在のアプリ/サイト
            if !engine.currentApp.isEmpty {
                Divider()
                HStack(spacing: 4) {
                    Circle()
                        .fill(engine.focusState?.phase.color ?? .gray)
                        .frame(width: 6, height: 6)
                    Text(engine.currentApp)
                        .font(.caption)
                        .foregroundStyle(.primary)
                    if let site = engine.currentSite, site != engine.currentApp {
                        Text("· \(site)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    // 分類状態
                    let classification = engine.siteObserver.effectiveClassification(
                        for: engine.currentSite ?? engine.currentApp
                    )
                    if classification == .flow {
                        Text("FLOW")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.sitboneFlow)
                    } else if classification == .drift {
                        Text("DRIFT")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.sitboneDrift)
                    }
                }
            }

            // 累計時間 (ADR-0012)
            if engine.cachedCumulative.totalFocusedHours > 0 {
                Divider()
                HStack {
                    Text("Total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatCumulativeHours(engine.cachedCumulative.totalFocusedHours))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var inactiveView: some View {
        VStack(spacing: 4) {
            Text("No active session")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @State private var editingProfileId: UUID?
    @State private var editName: String = ""

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Profiles")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            ForEach(engine.profiles) { profile in
                let isActive = profile.id == engine.activeProfile.id
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(hue: profile.colorHue, saturation: 0.7, brightness: isActive ? 0.9 : 0.4))
                        .frame(width: 8, height: 8)

                    if editingProfileId == profile.id {
                        TextField("name", text: $editName)
                            .font(.caption)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                if !editName.isEmpty {
                                    engine.renameProfile(profile, to: editName)
                                }
                                editingProfileId = nil
                            }
                    } else {
                        Text(profile.name)
                            .font(.caption)
                            .foregroundStyle(isActive ? .primary : .secondary)

                        Spacer()

                        if !isActive {
                            Button("Switch") {
                                engine.switchProfile(to: profile)
                            }
                            .font(.caption)
                        } else {
                            Text("active")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }

                        // 編集ボタン
                        Button {
                            editingProfileId = profile.id
                            editName = profile.name
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)

                        // 削除（アクティブでなければ）
                        if !isActive && engine.profiles.count > 1 {
                            Button {
                                engine.deleteProfile(profile)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.red.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // 新規作成
            Button {
                let name = "profile \(engine.profiles.count)"
                let profile = engine.createProfile(name: name)
                editingProfileId = profile.id
                editName = name
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle")
                        .font(.caption)
                    Text("New Profile")
                        .font(.caption)
                }
            }
        }
    }

    private var sessionToggle: some View {
        Button {
            if engine.isSessionActive {
                engine.endSession()
            } else {
                engine.startSession()
            }
        } label: {
            HStack {
                Image(systemName: engine.isSessionActive ? "stop.fill" : "play.fill")
                Text(engine.isSessionActive ? "End Session" : "Start Session")
            }
        }
        .keyboardShortcut("s", modifiers: [.command, .shift])
    }

    private func counterItem(_ symbol: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Text(symbol)
                .foregroundStyle(color)
            Text("\(count)")
                .font(.system(.body, design: .monospaced))
        }
    }
}

// MARK: - Time formatting

func formatTime(_ interval: TimeInterval) -> String {
    let hours = Int(interval) / 3600
    let minutes = (Int(interval) % 3600) / 60
    let seconds = Int(interval) % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
}

func formatCumulativeHours(_ hours: Double) -> String {
    if hours >= 1.0 {
        return String(format: "%.1fh", hours)
    }
    let minutes = Int(hours * 60)
    return "\(minutes)m"
}

// MARK: - MenuBar Icon

/// macOS標準のテンプレートアイコン（くり抜き▽ + 状態ドット）
public func menuBarIcon(phase: FocusPhase?) -> NSImage {
    let size = NSSize(width: 18, height: 18)

    // テンプレートアイコン（黒で描画、OSがダーク/ライトモードに合わせて着色）
    let template = NSImage(size: size, flipped: true) { rect in
        let inset: CGFloat = 1.5
        let top = inset
        let bottom = rect.maxY - inset
        let left = rect.minX + inset
        let right = rect.maxX - inset
        let midX = rect.midX
        let cornerRadius: CGFloat = 2.5

        // 角丸の逆三角形パスを作成
        let path = NSBezierPath()

        // 左上角（角丸）
        path.move(to: NSPoint(x: left + cornerRadius, y: top))
        // 上辺
        path.line(to: NSPoint(x: right - cornerRadius, y: top))
        // 右上角（角丸）
        path.curve(
            to: NSPoint(x: right, y: top + cornerRadius),
            controlPoint1: NSPoint(x: right, y: top),
            controlPoint2: NSPoint(x: right, y: top)
        )
        // 右辺→下頂点
        path.line(to: NSPoint(x: midX + cornerRadius * 0.5, y: bottom - cornerRadius))
        // 下頂点（角丸）
        path.curve(
            to: NSPoint(x: midX - cornerRadius * 0.5, y: bottom - cornerRadius),
            controlPoint1: NSPoint(x: midX, y: bottom),
            controlPoint2: NSPoint(x: midX, y: bottom)
        )
        // 左辺
        path.line(to: NSPoint(x: left, y: top + cornerRadius))
        // 左上角（角丸）
        path.curve(
            to: NSPoint(x: left + cornerRadius, y: top),
            controlPoint1: NSPoint(x: left, y: top),
            controlPoint2: NSPoint(x: left, y: top)
        )
        path.close()

        // アウトライン（くり抜き）: ストロークのみ
        NSColor.black.setStroke()
        path.lineWidth = 1.5
        path.stroke()

        // セッション中なら中央に小さなドット
        if phase == .flow || phase == .drift {
            let dotSize: CGFloat = 3.5
            let dotRect = NSRect(
                x: midX - dotSize / 2,
                y: (top + bottom) / 2 - dotSize / 2 - 1,
                width: dotSize,
                height: dotSize
            )
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }

        return true
    }
    template.isTemplate = true
    return template
}
