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
    private let hoverState = HoverState()

    public init(engine: SessionEngine) {
        self.engine = engine
    }

    public func show() {
        guard leftPanel == nil else { return }
        let geo = NotchGeometry.detect()
        self.geo = geo

        // 左翼: notchに溶け込むミニマルな翼（グローインジケーターに合わせた最小幅）
        let wingWidth: CGFloat = 20
        let h = geo.notchHeight
        leftPanel = makePanel(
            frame: NSRect(x: geo.notchLeft - wingWidth, y: geo.notchBottomY, width: wingWidth, height: h),
            content: LeftWing(engine: engine, height: h),
            interactive: false
        )

        // 右翼: コンパクト (notch直右)
        rightPanel = makePanel(
            frame: NSRect(x: geo.notchRight, y: geo.notchBottomY, width: wingWidth, height: h),
            content: RightWing(engine: engine, height: h),
            interactive: false
        )

        // ホバー検出パネル: notch領域全体 (透明、マウスイベントのみ)
        let hoverWidth = geo.notchRight - geo.notchLeft + wingWidth * 2
        let hoverX = geo.notchLeft - wingWidth
        let hoverPanel = makePanel(
            frame: NSRect(x: hoverX, y: geo.notchBottomY - 120, width: hoverWidth, height: h + 120),
            content: HoverDetector(
                engine: engine,
                hoverState: hoverState,
                notchWidth: geo.notchRight - geo.notchLeft,
                wingWidth: wingWidth
            ),
            interactive: true
        )
        hoverPanel.ignoresMouseEvents = false
        self.expandPanel = hoverPanel

        leftPanel?.orderFrontRegardless()
        rightPanel?.orderFrontRegardless()
        hoverPanel.orderFrontRegardless()
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

// MARK: - Hover State (共有)

@MainActor
final class HoverState: ObservableObject {
    @Published var isHovering = false
}

// MARK: - Left Wing (notchからスライドして出現)

struct LeftWing: View {
    @ObservedObject var engine: SessionEngine
    let height: CGFloat
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .trailing) {
            WingShape(side: .left).fill(.black)

            if engine.isSessionActive {
                // notch側端にグローライン
                RoundedRectangle(cornerRadius: 1)
                    .fill(phaseColor.opacity(0.7))
                    .frame(width: 2, height: height * 0.45)
                    .shadow(color: phaseColor.opacity(0.5), radius: 6)
                    .padding(.trailing, 1)
            }
        }
        .frame(height: height)
        // notchの中から左にスライドして出現
        .offset(x: appeared ? 0 : 20)
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

// MARK: - Right Wing (notchからスライドして出現)

struct RightWing: View {
    @ObservedObject var engine: SessionEngine
    let height: CGFloat
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .leading) {
            WingShape(side: .right).fill(.black)

            if engine.isSessionActive {
                RoundedRectangle(cornerRadius: 1)
                    .fill(phaseColor.opacity(0.7))
                    .frame(width: 2, height: height * 0.45)
                    .shadow(color: phaseColor.opacity(0.5), radius: 6)
                    .padding(.leading, 1)
            }
        }
        .frame(height: height)
        // notchの中から右にスライドして出現
        .offset(x: appeared ? 0 : -20)
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

// MARK: - Hover Detector + Expand Panel

struct HoverDetector: View {
    @ObservedObject var engine: SessionEngine
    @ObservedObject var hoverState: HoverState
    let notchWidth: CGFloat
    let wingWidth: CGFloat
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            // 上部: 透明なホバー検出エリア（notch + 翼の幅）
            Color.clear
                .frame(height: 32)

            // 下部: 展開パネル（ホバー時のみ表示）
            if isHovering && engine.isSessionActive {
                expandedContent
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isHovering = hovering
                hoverState.isHovering = hovering
            }
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 6) {
            // 状態 + Honest Clock
            HStack {
                Circle()
                    .fill(phaseColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: phaseColor.opacity(0.5), radius: 3)
                Text(engine.focusState?.phase.label ?? "")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(phaseColor)
                Spacer()
                Text(formatCompactTime(engine.focusedElapsed))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(phaseColor)
                Text("/")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
                Text(formatCompactTime(engine.totalElapsed))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }

            // タイムライン + Ratio
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.white.opacity(0.1))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(phaseColor.opacity(0.7))
                            .frame(width: max(2, geo.size.width * engine.focusRatio))
                    }
                }
                .frame(height: 4)

                Text("\(Int(engine.focusRatio * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize()
            }

            // カウンタ
            HStack(spacing: 12) {
                counterItem("↩", engine.counters.driftRecovered.value, Color.sitboneFlow)
                counterItem("←", engine.counters.awayRecovered.value, Color.sitboneAccent)
                counterItem("✕", engine.counters.deserted.value, Color.sitboneAway)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: notchWidth + wingWidth * 2 - 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.black.opacity(0.9))
                .shadow(color: phaseColor.opacity(0.15), radius: 8, y: 4)
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
    // 外側の角丸をnotchの角丸に合わせる（macOS notchは約10pt角丸）
    let radius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch side {
        case .left:
            // 上辺: 左上が角丸、右上はnotchに直結（直角）
            p.move(to: CGPoint(x: radius, y: 0))
            p.addLine(to: CGPoint(x: rect.maxX, y: 0))         // → notch接合（直角）
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)) // ↓ notch接合（直角）
            p.addLine(to: CGPoint(x: radius, y: rect.maxY))
            // 左下の角丸
            p.addArc(center: CGPoint(x: radius, y: rect.maxY - radius),
                      radius: radius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: CGPoint(x: 0, y: radius))
            // 左上の角丸
            p.addArc(center: CGPoint(x: radius, y: radius),
                      radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)

        case .right:
            // 上辺: 左上はnotchに直結（直角）、右上が角丸
            p.move(to: CGPoint(x: 0, y: 0))                    // notch接合（直角）
            p.addLine(to: CGPoint(x: rect.maxX - radius, y: 0))
            // 右上の角丸
            p.addArc(center: CGPoint(x: rect.maxX - radius, y: radius),
                      radius: radius, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            // 右下の角丸
            p.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                      radius: radius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: 0, y: rect.maxY))         // notch接合（直角）
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
