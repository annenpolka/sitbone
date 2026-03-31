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

        // 翼: notchに2ptオーバーラップして隙間をなくす
        let wingWidth: CGFloat = 22
        let overlap: CGFloat = 2
        let h = geo.notchHeight
        leftPanel = makePanel(
            frame: NSRect(x: geo.notchLeft - wingWidth + overlap, y: geo.notchBottomY, width: wingWidth, height: h),
            content: LeftWing(engine: engine, height: h),
            interactive: false
        )

        rightPanel = makePanel(
            frame: NSRect(x: geo.notchRight - overlap, y: geo.notchBottomY, width: wingWidth, height: h),
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
    // 外側: notchの物理的な角丸に合わせる
    let outerR: CGFloat = 8
    // 内側(notch側): 凹面カーブでnotchの角に滑らかに接続
    let innerR: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch side {
        case .left:
            // 左上: 外側の角丸（凸）
            p.move(to: CGPoint(x: outerR, y: 0))
            // 上辺 → notch側の手前で止まる
            p.addLine(to: CGPoint(x: rect.maxX, y: 0))
            // 右上: notchの角に凹面カーブで接続
            // notchの角は下に向かって丸いので、翼の右上は凹面で受ける
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - innerR))
            p.addArc(
                center: CGPoint(x: rect.maxX + innerR, y: rect.maxY - innerR),
                radius: innerR,
                startAngle: .degrees(180),
                endAngle: .degrees(90),
                clockwise: true  // 凹面（時計回り = 内側にくぼむ）
            )
            // 下辺
            p.addLine(to: CGPoint(x: outerR, y: rect.maxY))
            // 左下: 外側の角丸（凸）
            p.addArc(
                center: CGPoint(x: outerR, y: rect.maxY - outerR),
                radius: outerR, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
            )
            // 左辺
            p.addLine(to: CGPoint(x: 0, y: outerR))
            // 左上: 外側の角丸（凸）
            p.addArc(
                center: CGPoint(x: outerR, y: outerR),
                radius: outerR, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false
            )

        case .right:
            // 左上: notchの角に凹面カーブで接続
            p.move(to: CGPoint(x: 0, y: rect.maxY))
            p.addLine(to: CGPoint(x: 0, y: rect.maxY - innerR))
            // 凹面でnotchの左下角に接続
            // notch右下の角は上に丸いので、翼の左上は凹面で受ける
            // Wait - the notch curves happen at the bottom of the notch
            // From the wing's perspective (flipped y in SwiftUI): top of wing connects to notch bottom
            p.addArc(
                center: CGPoint(x: -innerR, y: rect.maxY - innerR),
                radius: innerR,
                startAngle: .degrees(0),
                endAngle: .degrees(270),
                clockwise: true
            )
            // 上辺
            // Actually let me redo this more carefully
            p = Path()
            // notch側の凹面接続から開始
            p.move(to: CGPoint(x: 0, y: 0))
            // 上辺 → 右上
            p.addLine(to: CGPoint(x: rect.maxX - outerR, y: 0))
            // 右上: 外側の角丸
            p.addArc(
                center: CGPoint(x: rect.maxX - outerR, y: outerR),
                radius: outerR, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false
            )
            // 右辺
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - outerR))
            // 右下: 外側の角丸
            p.addArc(
                center: CGPoint(x: rect.maxX - outerR, y: rect.maxY - outerR),
                radius: outerR, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
            )
            // 下辺 → notch側
            p.addLine(to: CGPoint(x: 0, y: rect.maxY))
            // 左下: notchの角に凹面カーブで接続
            p.addArc(
                center: CGPoint(x: -innerR, y: rect.maxY - innerR),
                radius: innerR,
                startAngle: .degrees(90),
                endAngle: .degrees(0),
                clockwise: true
            )
            p.addLine(to: CGPoint(x: 0, y: 0))
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
