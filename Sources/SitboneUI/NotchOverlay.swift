// NotchOverlay — ノッチ左右にコンパクトな翼 + ホバーで詳細展開
// ADR-0006

import SwiftUI
import AppKit
import CoreGraphics
import Combine
public import SitboneCore
import SitboneData

// MARK: - Notch Geometry

struct NotchGeometry: Sendable {
    let screenFrame: CGRect
    let notchLeft: CGFloat
    let notchRight: CGFloat
    let notchBottomY: CGFloat
    let notchHeight: CGFloat
    let hasNotch: Bool

    @MainActor
    static func detect() -> NotchGeometry {
        let screen = builtInScreen() ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.frame
        let safe = screen.safeAreaInsets
        let hasNotch = safe.top > 0

        if hasNotch,
           let leftEar = screen.auxiliaryTopLeftArea,
           let rightEar = screen.auxiliaryTopRightArea {
            return NotchGeometry(
                screenFrame: frame,
                notchLeft: leftEar.maxX,
                notchRight: rightEar.minX,
                notchBottomY: frame.maxY - safe.top,
                notchHeight: safe.top,
                hasNotch: true
            )
        } else {
            let menuH: CGFloat = 25
            return NotchGeometry(
                screenFrame: frame,
                notchLeft: frame.midX - 90,
                notchRight: frame.midX + 90,
                notchBottomY: frame.maxY - menuH,
                notchHeight: menuH,
                hasNotch: false
            )
        }
    }

    @MainActor
    private static func builtInScreen() -> NSScreen? {
        for screen in NSScreen.screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               CGDisplayIsBuiltin(id) != 0 {
                return screen
            }
        }
        return nil
    }
}

// MARK: - NotchOverlayController

@MainActor
public final class NotchOverlayController {
    private var leftPanel: NSPanel?
    private var rightPanel: NSPanel?
    private var expandPanel: NSPanel?
    private var ghostPanel: NSPanel?
    private let engine: SessionEngine
    private var geo: NotchGeometry?
    public var onSettingsTap: (() -> Void)?

    public init(engine: SessionEngine) {
        self.engine = engine
    }

    public func show() {
        guard leftPanel == nil else { return }
        let geo = NotchGeometry.detect()
        self.geo = geo

        // 翼: notchの裏に大きくオーバーラップ（接合部をnotchが隠す）
        let visibleWidth: CGFloat = 14  // notchから出て見える部分
        let overlapInto: CGFloat = 16   // notchの裏に隠れる部分
        let totalWidth = visibleWidth + overlapInto
        let h = geo.notchHeight
        leftPanel = makePanel(
            frame: NSRect(x: geo.notchLeft - visibleWidth, y: geo.notchBottomY, width: totalWidth, height: h),
            content: LeftWing(engine: engine, height: h),
            interactive: false
        )

        // 右翼: 左翼と同じグローラインインジケーター
        rightPanel = makePanel(
            frame: NSRect(x: geo.notchRight - overlapInto, y: geo.notchBottomY, width: totalWidth, height: h),
            content: RightWing(engine: engine, height: h),
            interactive: false
        )

        // ホバーパネル: notchと同幅、下に展開 (Claude Island風)
        let notchWidth = geo.notchRight - geo.notchLeft
        let expandHeight: CGFloat = 240  // リバー表示時に十分な高さ
        let expandPanel = makePanel(
            frame: NSRect(
                x: geo.notchLeft,
                y: geo.notchBottomY - expandHeight,
                width: notchWidth,
                height: expandHeight + h  // notch高さ分もカバー（ホバー検出用）
            ),
            content: NotchDropdown(
                engine: engine,
                notchWidth: notchWidth,
                notchHeight: h,
                onSettingsTap: { [weak self] in
                    self?.onSettingsTap?()
                }
            ),
            interactive: true
        )
        expandPanel.ignoresMouseEvents = false
        self.expandPanel = expandPanel

        // Ghost Teacherバナー: フォーカスディスプレイの上端中央に表示
        setupGhostPanel()

        leftPanel?.orderFrontRegardless()
        rightPanel?.orderFrontRegardless()
        expandPanel.orderFrontRegardless()
        ghostPanel?.orderFrontRegardless()
    }

    public func hide() {
        leftPanel?.close(); rightPanel?.close(); expandPanel?.close(); ghostPanel?.close()
        leftPanel = nil; rightPanel = nil; expandPanel = nil; ghostPanel = nil
    }

    public var isVisible: Bool { leftPanel != nil }

    /// Ghost Teacherパネルをフォーカスディスプレイの上端中央に配置
    private func setupGhostPanel() {
        ghostPanel?.close()
        ghostPanel = nil

        // NSScreen.main = フォーカスのあるディスプレイ
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        let safe = screen.safeAreaInsets
        let topY = frame.maxY - safe.top  // メニューバー/notchの下端

        let ghostWidth: CGFloat = 280
        let ghostHeight: CGFloat = 64
        let ghostX = frame.midX - ghostWidth / 2
        let ghostY = topY - ghostHeight - 6

        let gp = makePanel(
            frame: NSRect(x: ghostX, y: ghostY, width: ghostWidth, height: ghostHeight),
            content: GhostTeacherBanner(engine: engine, onReposition: { [weak self] in
                // サイトが変わるたびにフォーカスディスプレイに再配置
                self?.repositionGhostPanel()
            }),
            interactive: true
        )
        gp.ignoresMouseEvents = false
        self.ghostPanel = gp
    }

    private func repositionGhostPanel() {
        guard let panel = ghostPanel else { return }
        let screen = screenOfFocusedWindow() ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.frame
        let safe = screen.safeAreaInsets
        let topY = frame.maxY - safe.top

        let ghostWidth: CGFloat = 280
        let ghostHeight: CGFloat = 64
        let ghostX = frame.midX - ghostWidth / 2
        let ghostY = topY - ghostHeight - 6

        panel.setFrame(NSRect(x: ghostX, y: ghostY, width: ghostWidth, height: ghostHeight), display: true)
        panel.orderFrontRegardless()
    }

    /// フォーカスウィンドウが表示されているスクリーンを取得
    private func screenOfFocusedWindow() -> NSScreen? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value)
        guard err == .success, let window = value else { return nil }

        var posValue: AnyObject?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXPositionAttribute as CFString, &posValue)
        guard let posValue else { return nil }

        var point = CGPoint.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &point)

        // CGのy座標系（上が0）→ NSScreenのy座標系（下が0）に変換
        // NSScreen.screens[0]がプライマリ（一番高いmaxYを持つ）
        if let primaryHeight = NSScreen.screens.first?.frame.height {
            point.y = primaryHeight - point.y
        }

        // ウィンドウ位置を含むスクリーンを探す
        for screen in NSScreen.screens {
            if screen.frame.contains(point) {
                return screen
            }
        }
        return nil
    }

    private func makePanel<V: View>(frame: NSRect, content: V, interactive: Bool) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = !interactive

        let host = NSHostingView(rootView: content)
        host.layer?.backgroundColor = .clear
        panel.contentView = host
        return panel
    }
}

// MARK: - Left Wing (notchからスライドして出現)

struct LeftWing: View {
    @ObservedObject var engine: SessionEngine
    let height: CGFloat
    @State private var appeared = false
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        ZStack(alignment: .leading) {
            WingShape(side: .left).fill(.black)

            if engine.isSessionActive {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(profilePhaseColor)
                    .frame(width: 2.5, height: height * 0.4)
                    .shadow(color: profilePhaseColor, radius: 8)
                    .shadow(color: profilePhaseColor.opacity(0.5), radius: 3)
                    .padding(.leading, 3)
                    .animation(.easeInOut(duration: 0.8), value: engine.focusState?.phase)
            }
        }
        .frame(height: height)
        .scaleEffect(x: pulseScale, anchor: .trailing)
        .offset(x: appeared ? 0 : 14)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.1)) {
                appeared = true
            }
        }
        .onChange(of: engine.focusState?.phase) { _, newPhase in
            if newPhase == .drift {
                withAnimation(.spring(response: 0.15, dampingFraction: 0.3)) {
                    pulseScale = 2.5
                }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.15)) {
                    pulseScale = 1.0
                }
            }
        }
    }

    /// プロファイルカラー × 状態: FLOW=明るい、DRIFT=暗い脈動、AWAY=gray
    private var profilePhaseColor: Color {
        let hue = engine.activeProfile.colorHue
        switch engine.focusState?.phase {
        case .flow: return Color(hue: hue, saturation: 0.7, brightness: 0.9)
        case .drift: return Color(hue: hue, saturation: 0.5, brightness: 0.5)
        case .away, nil: return .gray
        }
    }
}

struct RightWing: View {
    @ObservedObject var engine: SessionEngine
    let height: CGFloat
    @State private var appeared = false
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        ZStack(alignment: .trailing) {
            WingShape(side: .right).fill(.black)

            if engine.isSessionActive {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(profilePhaseColor)
                    .frame(width: 2.5, height: height * 0.4)
                    .shadow(color: profilePhaseColor, radius: 8)
                    .shadow(color: profilePhaseColor.opacity(0.5), radius: 3)
                    .padding(.trailing, 3)
                    .animation(.easeInOut(duration: 0.8), value: engine.focusState?.phase)
            }
        }
        .frame(height: height)
        .scaleEffect(x: pulseScale, anchor: .leading)
        .offset(x: appeared ? 0 : -14)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.15)) {
                appeared = true
            }
        }
        .onChange(of: engine.focusState?.phase) { _, newPhase in
            if newPhase == .drift {
                withAnimation(.spring(response: 0.15, dampingFraction: 0.3)) {
                    pulseScale = 2.5
                }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.15)) {
                    pulseScale = 1.0
                }
            }
        }
    }

    private var profilePhaseColor: Color {
        let hue = engine.activeProfile.colorHue
        switch engine.focusState?.phase {
        case .flow: return Color(hue: hue, saturation: 0.7, brightness: 0.9)
        case .drift: return Color(hue: hue, saturation: 0.5, brightness: 0.5)
        case .away, nil: return .gray
        }
    }
}

// MARK: - Notch Dropdown (Claude Island風: notchから下に展開)

struct NotchDropdown: View {
    @ObservedObject var engine: SessionEngine
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    var onSettingsTap: (() -> Void)?  // unused now, kept for API compat
    @State private var isHovering = false
    @State private var showRiver = false

    var body: some View {
        VStack(spacing: 0) {
            // 上部: notch領域（透明、ホバー検出用）
            Color.clear
                .frame(height: notchHeight)

            // 下部: ドロップダウン（背景が上に伸びているので角は常に隠れる）
            if engine.isSessionActive {
                dropdownContent
                    .offset(y: isHovering ? 0 : -120)
                    .opacity(isHovering ? 1 : 0)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onHover { hovering in
            // Ghost Teacher表示中はドロップダウンのホバーを無視
            guard engine.pendingGhostTeacher == nil else {
                if isHovering {
                    withAnimation { isHovering = false; showRiver = false }
                }
                return
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isHovering = hovering
                if !hovering {
                    showRiver = false
                }
            }
        }
    }

    private var dropdownContent: some View {
        VStack(spacing: 0) {
            // Profile Pills（最上段）
            profilePills
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 4)

            if showRiver {
                riverContent
            } else {
                statsContent
            }
        }
        .frame(width: notchWidth)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 12,
                bottomTrailingRadius: 12,
                topTrailingRadius: 0
            )
            .fill(.black)
            .padding(.top, -50)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showRiver)
    }

    // MARK: Profile Pills

    private var profilePills: some View {
        HStack(spacing: 4) {
            ForEach(engine.profiles) { profile in
                let isActive = profile.id == engine.activeProfile.id
                Button {
                    if !isActive {
                        engine.switchProfile(to: profile)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Color(hue: profile.colorHue, saturation: 0.7, brightness: isActive ? 0.9 : 0.4))
                            .frame(width: 5, height: 5)
                        Text(profile.name)
                            .font(.system(size: 8, weight: isActive ? .bold : .regular))
                            .foregroundStyle(isActive ? .white : .white.opacity(0.35))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(isActive
                                  ? Color(hue: profile.colorHue, saturation: 0.5, brightness: 0.3)
                                  : .white.opacity(0.05))
                    )
                }
                .buttonStyle(.plain)
            }

            // [+] 新規作成: ワンタップで自動命名して作成
            Button {
                let name = "profile \(engine.profiles.count)"
                let p = engine.createProfile(name: name)
                engine.switchProfile(to: p)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.25))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(.white.opacity(0.05)))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
    }

    // MARK: Stats view

    private var statsContent: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(formatCompactTime(engine.focusedElapsed))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(phaseColor)
                    .fixedSize()
                Text("/")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.2))
                Text(formatCompactTime(engine.totalElapsed))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize()
                Spacer(minLength: 2)
                Text(engine.focusState?.phase.label ?? "")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(phaseColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(phaseColor.opacity(0.15))
                    .clipShape(Capsule())
                    .fixedSize()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(phaseColor.opacity(0.6))
                        .frame(width: max(2, geo.size.width * engine.focusRatio))
                }
            }
            .frame(height: 3)

            HStack(spacing: 6) {
                counterItem("↩", engine.counters.driftRecovered.value, Color.sitboneFlow)
                counterItem("←", engine.counters.awayRecovered.value, Color.sitboneAccent)
                counterItem("✕", engine.counters.deserted.value, Color.sitboneAway)
                Spacer(minLength: 0)
            }

            if !engine.currentApp.isEmpty {
                let target = engine.currentSite ?? engine.currentApp
                let cls = engine.siteObserver.effectiveClassification(for: target)
                HStack(spacing: 4) {
                    // 分類バッジ
                    Circle()
                        .fill(cls == .flow ? Color.sitboneFlow : cls == .drift ? Color.sitboneDrift : .white.opacity(0.2))
                        .frame(width: 5, height: 5)
                    Text(engine.currentApp)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                    if let site = engine.currentSite, site != engine.currentApp {
                        Text("· \(site)")
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    Spacer(minLength: 0)
                    if cls == .flow {
                        Text("FLOW")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Color.sitboneFlow.opacity(0.6))
                    } else if cls == .drift {
                        Text("DRIFT")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Color.sitboneDrift.opacity(0.6))
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                showRiver = true
            }
        }
    }

    // MARK: Inline River

    private var riverContent: some View {
        VStack(spacing: 4) {
            HStack {
                Button {
                    showRiver = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                Text("Focus River")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
            }

            // SiteObserverから動的に生成
            let sites = engine.siteObserver.allSuggestions()
            if sites.isEmpty {
                Text("No apps observed yet")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.vertical, 8)
            } else {
                ForEach(sites.prefix(8), id: \.site) { item in
                    LiveRiverRow(
                        site: item.site,
                        suggestion: item.suggestion,
                        totalTime: item.entry.totalTime,
                        onClassify: { classification in
                            engine.siteObserver.classify(site: item.site, as: classification)
                        }
                    )
                }
            }

            // 凡例
            HStack {
                Circle().fill(Color.sitboneFlow).frame(width: 4, height: 4)
                Text("FLOW")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.sitboneFlow.opacity(0.5))
                Spacer()
                Text("DRIFT")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.sitboneDrift.opacity(0.5))
                Circle().fill(Color.sitboneDrift).frame(width: 4, height: 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func counterItem(_ symbol: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Text(symbol)
                .font(.system(size: 9))
                .foregroundStyle(color)
            Text("\(count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var phaseColor: Color {
        engine.focusState?.phase.color ?? .gray
    }
}

// MARK: - Wing Shape (notch側が直角、外側が角丸)

enum WingSide { case left, right }

struct WingShape: Shape {
    let side: WingSide

    func path(in rect: CGRect) -> Path {
        // notchの裏に隠れる部分は直角でOK。見える外側だけ角丸。
        // notchの物理角丸 ≈ 7pt
        let r: CGFloat = 7
        var p = Path()
        switch side {
        case .left:
            // 左上を角丸、他は直角（右側はnotchの裏に隠れる）
            p.move(to: CGPoint(x: r, y: 0))
            p.addLine(to: CGPoint(x: rect.maxX, y: 0))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: r, y: rect.maxY))
            p.addArc(center: CGPoint(x: r, y: rect.maxY - r),
                      radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: CGPoint(x: 0, y: r))
            p.addArc(center: CGPoint(x: r, y: r),
                      radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        case .right:
            // 右上を角丸、他は直角（左側はnotchの裏に隠れる）
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: rect.maxX - r, y: 0))
            p.addArc(center: CGPoint(x: rect.maxX - r, y: r),
                      radius: r, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
                      radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: 0, y: rect.maxY))
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - Live River Row (SiteObserverベース、2値トグル)

struct LiveRiverRow: View {
    let site: String
    let suggestion: SiteSuggestion
    let totalTime: TimeInterval
    let onClassify: (SiteSuggestion) -> Void

    private var isFlow: Bool { suggestion == .flow }
    private var isDrift: Bool { suggestion == .drift }

    var body: some View {
        HStack(spacing: 4) {
            // 使用時間バー（視覚的な重み）
            RoundedRectangle(cornerRadius: 1)
                .fill(barColor.opacity(0.4))
                .frame(width: max(2, min(20, CGFloat(totalTime / 60))), height: 8)

            // サイト/アプリ名
            Text(site)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)

            Spacer(minLength: 0)

            // FLOW/DRIFTトグル
            HStack(spacing: 0) {
                toggleBtn("F", isSelected: isFlow, color: Color.sitboneFlow) {
                    onClassify(.flow)
                }
                toggleBtn("D", isSelected: isDrift, color: Color.sitboneDrift) {
                    onClassify(.drift)
                }
            }
            .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.04)))
        }
        .padding(.vertical, 1)
    }

    private var barColor: Color {
        if isFlow { return Color.sitboneFlow }
        if isDrift { return Color.sitboneDrift }
        return .white
    }

    private func toggleBtn(_ label: String, isSelected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(isSelected ? color : .white.opacity(0.15))
                .frame(width: 18, height: 14)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isSelected ? color.opacity(0.15) : .clear)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Ghost Teacher Banner (notch下にぴょこっと出る)

struct GhostTeacherBanner: View {
    @ObservedObject var engine: SessionEngine
    var onReposition: (() -> Void)?
    @State private var visible = false

    var body: some View {
        VStack {
            Spacer(minLength: 0)

            if let site = engine.pendingGhostTeacher {
                HStack(spacing: 10) {
                    Text(site)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Button {
                        withAnimation { engine.classifySite(site, as: .flow) }
                    } label: {
                        Text("FLOW")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.sitboneFlow)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.sitboneFlow.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation { engine.classifySite(site, as: .drift) }
                    } label: {
                        Text("DRIFT")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.sitboneDrift)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.sitboneDrift.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation { engine.dismissGhostTeacher() }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.black.opacity(0.92))
                        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                )
                .offset(y: visible ? 0 : -30)
                .opacity(visible ? 1 : 0)
                .onAppear {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        visible = true
                    }
                }
                .onChange(of: engine.pendingGhostTeacher) { _, newSite in
                    if newSite != nil {
                        // フォーカスディスプレイに再配置してからアニメーション
                        onReposition?()
                        visible = false
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7).delay(0.15)) {
                            visible = true
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Colors

extension Color {
    static let sitboneFlow = Color(red: 0.176, green: 0.831, blue: 0.659)
    static let sitboneDrift = Color(red: 0.957, green: 0.659, blue: 0.239)
    static let sitboneAway = Color(red: 0.420, green: 0.447, blue: 0.498)
    static let sitboneAccent = Color(red: 0.506, green: 0.549, blue: 0.973)
}

// MARK: - Time formatting

func formatCompactTime(_ interval: TimeInterval) -> String {
    let h = Int(interval) / 3600
    let m = (Int(interval) % 3600) / 60
    let s = Int(interval) % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}

// MARK: - Visual Effect Background

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material; v.blendingMode = blendingMode; v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material; v.blendingMode = blendingMode
    }
}
