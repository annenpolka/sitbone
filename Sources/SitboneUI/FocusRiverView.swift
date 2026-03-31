// FocusRiverView — フォーカスリバー設定UI
// アプリを左(FLOW)と右(DRIFT)にドラッグして分類する

public import SwiftUI
import Combine
public import SitboneCore

// MARK: - App Entry (アプリごとの分類データ)

@MainActor
final class AppClassification: ObservableObject, Identifiable {
    let id: String  // アプリ名
    @Published var flowScore: Double  // -1.0(DRIFT) ~ 1.0(FLOW)
    @Published var totalTime: TimeInterval
    @Published var flowTime: TimeInterval

    init(name: String, flowScore: Double = 0, totalTime: TimeInterval = 0, flowTime: TimeInterval = 0) {
        self.id = name
        self.flowScore = flowScore
        self.totalTime = totalTime
        self.flowTime = flowTime
    }

    var flowRatio: Double {
        guard totalTime > 0 else { return 0.5 }
        return flowTime / totalTime
    }
}

// MARK: - FocusRiverView

public struct FocusRiverView: View {
    @ObservedObject var engine: SessionEngine
    @State private var apps: [AppClassification] = sampleApps()

    public init(engine: SessionEngine) {
        self.engine = engine
    }

    public var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            header
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Divider()
                .background(.white.opacity(0.1))

            // リバー
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(apps.sorted(by: { $0.flowScore > $1.flowScore })) { app in
                        AppRiverRow(app: app)
                    }
                }
                .padding(.vertical, 8)
            }

            Divider()
                .background(.white.opacity(0.1))

            // 凡例
            legend
                .padding(12)
        }
        .frame(width: 340, height: 400)
        .background(.black.opacity(0.95))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Focus River")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text("Drag the slider to classify each app")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private var legend: some View {
        HStack {
            Circle().fill(Color.sitboneFlow).frame(width: 6, height: 6)
            Text("FLOW")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.sitboneFlow)
            Spacer()
            Text("← drag →")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.2))
            Spacer()
            Text("DRIFT")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.sitboneDrift)
            Circle().fill(Color.sitboneDrift).frame(width: 6, height: 6)
        }
    }

    static func sampleApps() -> [AppClassification] {
        // 初期データ（将来は学習データから生成）
        [
            AppClassification(name: "VS Code", flowScore: 0.9, totalTime: 3600, flowTime: 3400),
            AppClassification(name: "Terminal", flowScore: 0.95, totalTime: 2000, flowTime: 1950),
            AppClassification(name: "Ghostty", flowScore: 0.92, totalTime: 1800, flowTime: 1700),
            AppClassification(name: "Firefox", flowScore: 0.3, totalTime: 1200, flowTime: 600),
            AppClassification(name: "Slack", flowScore: -0.3, totalTime: 800, flowTime: 200),
            AppClassification(name: "Twitter", flowScore: -0.9, totalTime: 300, flowTime: 10),
        ]
    }
}

// MARK: - App River Row (各アプリの行: スライダー)

struct AppRiverRow: View {
    @ObservedObject var app: AppClassification

    private var barColor: Color {
        if app.flowScore > 0.2 {
            return Color.sitboneFlow.opacity(0.3 + app.flowScore * 0.5)
        } else if app.flowScore < -0.2 {
            return Color.sitboneDrift.opacity(0.3 + abs(app.flowScore) * 0.5)
        }
        return .white.opacity(0.1)
    }

    var body: some View {
        HStack(spacing: 8) {
            // アプリ名
            Text(app.id)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 80, alignment: .trailing)

            // スライダー（川）
            GeometryReader { geo in
                let w = geo.size.width
                let center = w / 2
                let pos = center + CGFloat(app.flowScore) * center

                ZStack(alignment: .leading) {
                    // 川の背景
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.white.opacity(0.05))

                    // 中央線（川）
                    Rectangle()
                        .fill(.white.opacity(0.1))
                        .frame(width: 1)
                        .position(x: center, y: geo.size.height / 2)

                    // ドット（ドラッグ可能）
                    Circle()
                        .fill(dotColor)
                        .frame(width: 12, height: 12)
                        .shadow(color: dotColor.opacity(0.5), radius: 4)
                        .position(x: pos, y: geo.size.height / 2)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let newScore = (value.location.x - center) / center
                                    app.flowScore = max(-1, min(1, Double(newScore)))
                                }
                        )

                    // スコアバー（中央からドットまで）
                    let barStart = min(center, pos)
                    let barWidth = abs(pos - center)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(width: max(2, barWidth), height: 4)
                        .position(x: barStart + barWidth / 2, y: geo.size.height / 2)
                }
            }
            .frame(height: 24)

            // Flow率
            Text("\(Int(app.flowRatio * 100))%")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
                .frame(width: 30, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    private var dotColor: Color {
        if app.flowScore > 0.2 { return Color.sitboneFlow }
        if app.flowScore < -0.2 { return Color.sitboneDrift }
        return .white.opacity(0.5)
    }
}

// MARK: - Settings Window Controller

@MainActor
public final class SettingsWindowController {
    private var window: NSWindow?
    private let engine: SessionEngine

    public init(engine: SessionEngine) {
        self.engine = engine
    }

    public func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            return
        }

        let riverView = FocusRiverView(engine: engine)
        let host = NSHostingView(rootView: riverView)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Focus River"
        w.contentView = host
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        self.window = w
    }
}
