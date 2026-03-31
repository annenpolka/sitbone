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
    private let engine: SessionEngine
    private var geo: NotchGeometry?

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

        rightPanel = makePanel(
            frame: NSRect(x: geo.notchRight - overlapInto, y: geo.notchBottomY, width: totalWidth, height: h),
            content: RightWing(engine: engine, height: h),
            interactive: false
        )

        // ホバーパネル: notchと同幅、下に展開 (Claude Island風)
        let notchWidth = geo.notchRight - geo.notchLeft
        let expandHeight: CGFloat = 180
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
                notchHeight: h
            ),
            interactive: true
        )
        expandPanel.ignoresMouseEvents = false
        self.expandPanel = expandPanel

        leftPanel?.orderFrontRegardless()
        rightPanel?.orderFrontRegardless()
        expandPanel.orderFrontRegardless()
    }

    public func hide() {
        leftPanel?.close(); rightPanel?.close(); expandPanel?.close()
        leftPanel = nil; rightPanel = nil; expandPanel = nil
    }

    public var isVisible: Bool { leftPanel != nil }

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

    var body: some View {
        ZStack(alignment: .leading) {  // グローを外側（左端）に
            WingShape(side: .left).fill(.black)

            if engine.isSessionActive {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(phaseColor)
                    .frame(width: 2.5, height: height * 0.4)
                    .shadow(color: phaseColor, radius: 8)
                    .shadow(color: phaseColor.opacity(0.5), radius: 3)
                    .padding(.leading, 3)
            }
        }
        .frame(height: height)
        .offset(x: appeared ? 0 : 14)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.1)) {
                appeared = true
            }
        }
    }

    private var phaseColor: Color {
        engine.focusState?.phase.color ?? .gray
    }
}

struct RightWing: View {
    @ObservedObject var engine: SessionEngine
    let height: CGFloat
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .trailing) {  // グローを外側（右端）に
            WingShape(side: .right).fill(.black)

            if engine.isSessionActive {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(phaseColor)
                    .frame(width: 2.5, height: height * 0.4)
                    .shadow(color: phaseColor, radius: 8)
                    .shadow(color: phaseColor.opacity(0.5), radius: 3)
                    .padding(.trailing, 3)
            }
        }
        .frame(height: height)
        .offset(x: appeared ? 0 : -14)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.15)) {
                appeared = true
            }
        }
    }

    private var phaseColor: Color {
        engine.focusState?.phase.color ?? .gray
    }
}

// MARK: - Notch Dropdown (Claude Island風: notchから下に展開)

struct NotchDropdown: View {
    @ObservedObject var engine: SessionEngine
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            // 上部: notch領域（透明、ホバー検出用）
            Color.clear
                .frame(height: notchHeight)

            // 下部: ドロップダウンパネル
            if isHovering && engine.isSessionActive {
                dropdownContent
                    .transition(.asymmetric(
                        insertion: .push(from: .top).combined(with: .opacity),
                        removal: .push(from: .bottom).combined(with: .opacity)
                    ))
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isHovering = hovering
            }
        }
    }

    private var dropdownContent: some View {
        VStack(spacing: 8) {
            // Honest Clock (大きく)
            HStack(alignment: .firstTextBaseline) {
                Text(formatCompactTime(engine.focusedElapsed))
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(phaseColor)
                Text("/")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.2))
                Text(formatCompactTime(engine.totalElapsed))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                // 状態バッジ
                Text(engine.focusState?.phase.label ?? "")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(phaseColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(phaseColor.opacity(0.15))
                    .clipShape(Capsule())
            }

            // タイムラインバー
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(phaseColor.opacity(0.6))
                        .frame(width: max(2, geo.size.width * engine.focusRatio))
                }
            }
            .frame(height: 3)

            // カウンタ + 現在のアプリ
            HStack {
                counterItem("↩", engine.counters.driftRecovered.value, Color.sitboneFlow)
                counterItem("←", engine.counters.awayRecovered.value, Color.sitboneAccent)
                counterItem("✕", engine.counters.deserted.value, Color.sitboneAway)

                Spacer()

                // 現在のアプリ名
                if !engine.currentApp.isEmpty {
                    Text(engine.currentApp)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: notchWidth)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,     // notchに直結
                bottomLeadingRadius: 14,
                bottomTrailingRadius: 14,
                topTrailingRadius: 0      // notchに直結
            )
            .fill(.black.opacity(0.92))
        )
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
