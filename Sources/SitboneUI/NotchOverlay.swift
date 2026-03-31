// NotchOverlay — Notch下に常時表示するタイムラインバー (Layer 1)

import SwiftUI
import AppKit
public import SitboneCore
public import SitboneData

// MARK: - NotchOverlayController

@MainActor
public final class NotchOverlayController {
    private var panel: NSPanel?
    private let engine: SessionEngine

    public init(engine: SessionEngine) {
        self.engine = engine
    }

    public func show() {
        guard panel == nil else { return }
        guard let screen = NSScreen.main else { return }

        let barWidth: CGFloat = 280
        let barHeight: CGFloat = 48
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame

        // Notch下（画面上端中央）に配置
        let x = screenFrame.midX - barWidth / 2
        let y = screenFrame.maxY - barHeight - 6  // メニューバーの少し下

        let rect = NSRect(x: x, y: y, width: barWidth, height: barHeight)

        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true

        let hostView = NSHostingView(rootView: NotchBarView(engine: engine))
        panel.contentView = hostView

        panel.orderFrontRegardless()
        self.panel = panel
    }

    public func hide() {
        panel?.close()
        panel = nil
    }

    public var isVisible: Bool { panel != nil }
}

// MARK: - NotchBarView

struct NotchBarView: View {
    @ObservedObject var engine: SessionEngine
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            if isHovering && engine.isSessionActive {
                expandedView
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            compactBar
        }
        .background(
            VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isHovering = hovering
            }
        }
    }

    // MARK: - Compact Bar (常時表示)

    private var compactBar: some View {
        HStack(spacing: 6) {
            // タイムラインバー
            timelineBar
                .frame(height: 4)

            // 時間表示
            if engine.isSessionActive {
                Text(formatTime(engine.focusedElapsed))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(phaseColor)
                    .fixedSize()
            } else {
                Text("--:--")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 280)
    }

    // MARK: - Expanded View (ホバー時)

    private var expandedView: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 状態 + セッション名
            HStack {
                Circle()
                    .fill(phaseColor)
                    .frame(width: 8, height: 8)
                Text(engine.focusState?.phase.label ?? "IDLE")
                    .font(.caption.bold())
                    .foregroundStyle(phaseColor)
                Spacer()
                // Ratio
                Text("\(Int(engine.focusRatio * 100))%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Honest Clock
            HStack {
                Text(formatTime(engine.focusedElapsed))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.sitboneFlow)
                Text("/")
                    .foregroundStyle(.secondary)
                Text(formatTime(engine.totalElapsed))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
            }

            // カウンタ
            HStack(spacing: 12) {
                Label("\(engine.counters.driftRecovered.value)", systemImage: "arrow.uturn.backward")
                    .font(.caption2)
                    .foregroundStyle(Color.sitboneFlow)
                Label("\(engine.counters.awayRecovered.value)", systemImage: "arrow.backward")
                    .font(.caption2)
                    .foregroundStyle(Color.sitboneAccent)
                Label("\(engine.counters.deserted.value)", systemImage: "xmark")
                    .font(.caption2)
                    .foregroundStyle(Color.sitboneAway)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(width: 280)
    }

    // MARK: - Timeline Bar

    private var timelineBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // 背景
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.2))

                if engine.isSessionActive, engine.totalElapsed > 0 {
                    // 集中時間バー
                    RoundedRectangle(cornerRadius: 2)
                        .fill(phaseColor.opacity(0.8))
                        .frame(width: max(2, geo.size.width * engine.focusRatio))
                }
            }
        }
    }

    // MARK: - Helpers

    private var phaseColor: Color {
        engine.focusState?.phase.color ?? Color.sitboneAway
    }
}

// MARK: - Visual Effect Background

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
