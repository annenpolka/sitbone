// swiftlint:disable file_length
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
            if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               CGDisplayIsBuiltin(displayID) != 0 {
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
    private var ghostTeacherCancellable: AnyCancellable?
    private var hoverPollTimer: Timer?
    private let hoverState = HoverState()
    private var screenChangeObserver: Any?
    private var keyMonitor: Any?

    public init(engine: SessionEngine) {
        self.engine = engine
    }

    public func show() {
        guard leftPanel == nil else { return }
        let geometry = NotchGeometry.detect()
        self.geo = geometry

        setupWingPanels(with: geometry)
        setupExpandPanel(with: geometry)
        setupGhostPanel()
        orderPanelsFront()
        startHoverPolling()
        observeGhostTeacherChanges()
        observeScreenParameterChanges()
    }

    public func hide() {
        hoverPollTimer?.invalidate()
        hoverPollTimer = nil
        ghostTeacherCancellable?.cancel()
        removeKeyMonitor()
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            screenChangeObserver = nil
        }
        leftPanel?.close(); rightPanel?.close(); expandPanel?.close(); ghostPanel?.close()
        leftPanel = nil; rightPanel = nil; expandPanel = nil; ghostPanel = nil
    }

    public var isVisible: Bool { leftPanel != nil }

    private func setupWingPanels(with geometry: NotchGeometry) {
        let visibleWidth: CGFloat = 14
        let overlapInto: CGFloat = 16
        let totalWidth = visibleWidth + overlapInto
        let notchHeight = geometry.notchHeight

        leftPanel = makePanel(
            frame: NSRect(
                x: geometry.notchLeft - visibleWidth,
                y: geometry.notchBottomY,
                width: totalWidth,
                height: notchHeight
            ),
            content: LeftWing(engine: engine, height: notchHeight),
            interactive: false
        )

        rightPanel = makePanel(
            frame: NSRect(
                x: geometry.notchRight - overlapInto,
                y: geometry.notchBottomY,
                width: totalWidth,
                height: notchHeight
            ),
            content: RightWing(engine: engine, height: notchHeight),
            interactive: false
        )
    }

    private func setupExpandPanel(with geometry: NotchGeometry) {
        let notchWidth = geometry.notchRight - geometry.notchLeft
        let expandHeight: CGFloat = 350
        let expandPanel = makePanel(
            frame: NSRect(
                x: geometry.notchLeft,
                y: geometry.notchBottomY - expandHeight,
                width: notchWidth,
                height: expandHeight + geometry.notchHeight
            ),
            content: NotchDropdown(
                engine: engine,
                notchWidth: notchWidth,
                notchHeight: geometry.notchHeight,
                hoverState: hoverState
            ),
            interactive: true
        )
        expandPanel.ignoresMouseEvents = true
        self.expandPanel = expandPanel
    }

    private func orderPanelsFront() {
        leftPanel?.orderFrontRegardless()
        rightPanel?.orderFrontRegardless()
        expandPanel?.orderFrontRegardless()
        ghostPanel?.orderFrontRegardless()
    }

    private func observeGhostTeacherChanges() {
        ghostTeacherCancellable = engine.$pendingGhostTeacher
            .receive(on: RunLoop.main)
            .sink { [weak self] site in
                if site != nil {
                    self?.repositionGhostPanel()
                    self?.installKeyMonitor()
                } else {
                    self?.removeKeyMonitor()
                }
                self?.ghostPanel?.ignoresMouseEvents = site == nil
            }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let site = self.engine.pendingGhostTeacher else { return }
            let bindings = self.engine.ghostTeacherKeyBindings
            if event.matches(bindings.flow) {
                withAnimation { self.engine.classifySite(site, as: .flow) }
            } else if event.matches(bindings.drift) {
                withAnimation { self.engine.classifySite(site, as: .drift) }
            } else if event.matches(bindings.dismiss) {
                withAnimation { self.engine.dismissGhostTeacher() }
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    /// Ghost Teacherパネルをフォーカスディスプレイの上端中央に配置
    private func setupGhostPanel() {
        ghostPanel?.close()
        ghostPanel = nil

        // NSScreen.main = フォーカスのあるディスプレイ
        guard let screen = NSScreen.main else { return }
        let rect = ghostPanelFrame(screenFrame: screen.frame, safeTop: screen.safeAreaInsets.top)

        let ghostTeacherPanel = makePanel(
            frame: rect,
            content: GhostTeacherBanner(engine: engine, onReposition: { [weak self] in
                // サイトが変わるたびにフォーカスディスプレイに再配置
                self?.repositionGhostPanel()
            }),
            interactive: true
        )
        ghostTeacherPanel.ignoresMouseEvents = engine.pendingGhostTeacher == nil
        self.ghostPanel = ghostTeacherPanel
    }

    private func repositionGhostPanel() {
        guard let panel = ghostPanel else { return }
        let screen = screenOfFocusedWindow() ?? NSScreen.main ?? NSScreen.screens[0]
        let rect = ghostPanelFrame(screenFrame: screen.frame, safeTop: screen.safeAreaInsets.top)
        panel.setFrame(rect, display: true)
        panel.orderFrontRegardless()
    }

    // MARK: - マウス位置ベースのホバー制御

    private func startHoverPolling() {
        hoverPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMouseHover() }
        }
    }

    private func pollMouseHover() {
        guard let geo else { return }
        let mouse = NSEvent.mouseLocation
        let notchWidth = geo.notchRight - geo.notchLeft

        // ノッチ領域（ホバー開始トリガー）
        let notchRect = NSRect(
            x: geo.notchLeft, y: geo.notchBottomY,
            width: notchWidth, height: geo.notchHeight
        )

        // ドロップダウン領域（コンテンツ実測高さベース）
        let contentH = hoverState.contentHeight
        let dropdownRect = NSRect(
            x: geo.notchLeft,
            y: geo.notchBottomY - contentH,
            width: notchWidth,
            height: contentH
        )

        let inNotch = notchRect.contains(mouse)
        let inDropdown = dropdownRect.contains(mouse)
        let wasHovering = hoverState.isHovering

        // Ghost Teacher同画面チェック
        let ghostBlocks: Bool
        if engine.pendingGhostTeacher != nil,
           let ghostTeacherPanel = ghostPanel,
           let leftWingPanel = leftPanel,
           ghostTeacherPanel.screen == leftWingPanel.screen {
            ghostBlocks = true
        } else {
            ghostBlocks = false
        }

        if ghostBlocks {
            // Ghost Teacherが同画面 → ホバー無効
            if wasHovering { setHovering(false) }
            return
        }

        if inNotch || (wasHovering && inDropdown) {
            if !wasHovering { setHovering(true) }
        } else {
            if wasHovering { setHovering(false) }
        }
    }

    private func setHovering(_ hovering: Bool) {
        hoverState.isHovering = hovering
        // ドロップダウンのクリック操作を有効/無効
        expandPanel?.ignoresMouseEvents = !hovering

        // Ghost Teacherの表示制御
        if let ghostTeacherPanel = ghostPanel, let leftWingPanel = leftPanel {
            let sameScreen = ghostTeacherPanel.screen == leftWingPanel.screen
            ghostTeacherPanel.alphaValue = (hovering && sameScreen) ? 0 : 1
        }
    }

    /// フォーカスウィンドウが表示されているスクリーンを取得
    private func screenOfFocusedWindow() -> NSScreen? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindowValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            axApp,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )
        guard error == .success, let focusedWindowValue else { return nil }
        guard CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else { return nil }
        let focusedWindow = unsafeDowncast(focusedWindowValue, to: AXUIElement.self)

        var positionValue: CFTypeRef?
        AXUIElementCopyAttributeValue(focusedWindow, kAXPositionAttribute as CFString, &positionValue)
        guard let positionValue else { return nil }
        guard CFGetTypeID(positionValue) == AXValueGetTypeID() else { return nil }
        let windowPosition = unsafeDowncast(positionValue, to: AXValue.self)

        var point = CGPoint.zero
        AXValueGetValue(windowPosition, .cgPoint, &point)

        // CGのy座標系（上が0）→ NSScreenのy座標系（下が0）に変換
        // NSScreen.screens[0]がプライマリ（一番高いmaxYを持つ）
        if let primaryHeight = NSScreen.screens.first?.frame.height {
            point.y = primaryHeight - point.y
        }

        // ウィンドウ位置を含むスクリーンを探す
        for screen in NSScreen.screens where screen.frame.contains(point) {
            return screen
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

// MARK: - Screen Change Handling

extension NotchOverlayController {
    fileprivate func observeScreenParameterChanges() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.repositionAllPanels() }
        }
    }

    fileprivate func repositionAllPanels() {
        let geometry = NotchGeometry.detect()
        self.geo = geometry

        let visibleWidth: CGFloat = 14
        let overlapInto: CGFloat = 16
        let totalWidth = visibleWidth + overlapInto

        leftPanel?.setFrame(NSRect(
            x: geometry.notchLeft - visibleWidth,
            y: geometry.notchBottomY,
            width: totalWidth,
            height: geometry.notchHeight
        ), display: true)

        rightPanel?.setFrame(NSRect(
            x: geometry.notchRight - overlapInto,
            y: geometry.notchBottomY,
            width: totalWidth,
            height: geometry.notchHeight
        ), display: true)

        let notchWidth = geometry.notchRight - geometry.notchLeft
        let expandHeight: CGFloat = 350
        expandPanel?.setFrame(NSRect(
            x: geometry.notchLeft,
            y: geometry.notchBottomY - expandHeight,
            width: notchWidth,
            height: expandHeight + geometry.notchHeight
        ), display: true)

        repositionGhostPanel()
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
                    .fill(phaseColor)
                    .frame(width: 2.5, height: height * 0.4)
                    .shadow(color: phaseColor, radius: 8)
                    .shadow(color: phaseColor.opacity(0.5), radius: 3)
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

    private var phaseColor: Color {
        profilePhaseColor(phase: engine.focusState?.phase, hue: engine.activeProfile.colorHue)
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
                    .fill(phaseColor)
                    .frame(width: 2.5, height: height * 0.4)
                    .shadow(color: phaseColor, radius: 8)
                    .shadow(color: phaseColor.opacity(0.5), radius: 3)
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

    private var phaseColor: Color {
        profilePhaseColor(phase: engine.focusState?.phase, hue: engine.activeProfile.colorHue)
    }
}

// MARK: - PreferenceKey for content height

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - HoverState (コントローラ→SwiftUI間のホバー状態共有)

@MainActor
final class HoverState: ObservableObject {
    @Published var isHovering = false
    /// ドロップダウンコンテンツの実測高さ（GeometryReaderから更新）
    var contentHeight: CGFloat = 0
}

// MARK: - Notch Dropdown (Claude Island風: notchから下に展開)

struct NotchDropdown: View {
    @ObservedObject var engine: SessionEngine
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    @ObservedObject var hoverState: HoverState
    @State private var showRiver = false

    private var isHovering: Bool { hoverState.isHovering }

    var body: some View {
        VStack(spacing: 0) {
            // 上部: notch領域（透明スペーサー）
            Color.clear
                .frame(height: notchHeight)

            // 下部: ドロップダウン
            if engine.isSessionActive {
                dropdownContent
                    .background(GeometryReader { geo in
                        Color.clear.preference(
                            key: ContentHeightKey.self,
                            value: geo.size.height
                        )
                    })
                    .onPreferenceChange(ContentHeightKey.self) { height in
                        hoverState.contentHeight = height
                    }
                    .offset(y: isHovering ? 0 : -120)
                    .opacity(isHovering ? 1 : 0)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isHovering)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: isHovering) { _, hovering in
            if !hovering { showRiver = false }
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
                let profile = engine.createProfile(name: name)
                engine.switchProfile(to: profile)
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
                notchDropdownCounterItem("↩", engine.counters.driftRecovered.value, Color.sitboneFlow)
                notchDropdownCounterItem("←", engine.counters.awayRecovered.value, Color.sitboneAccent)
                notchDropdownCounterItem("✕", engine.counters.deserted.value, Color.sitboneAway)
                Spacer(minLength: 0)
                if engine.cachedCumulative.totalFocusedHours > 0 {
                    Text(formatCumulativeHours(engine.cachedCumulative.totalFocusedHours))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }

            if !engine.currentApp.isEmpty {
                let target = engine.currentSite ?? engine.currentApp
                let cls = engine.siteObserver.effectiveClassification(for: target)
                HStack(spacing: 4) {
                    // 分類バッジ
                    let classificationColor: Color =
                        if cls == .flow {
                            Color.sitboneFlow
                        } else if cls == .drift {
                            Color.sitboneDrift
                        } else {
                            .white.opacity(0.2)
                        }
                    Circle()
                        .fill(classificationColor)
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
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(sites, id: \.site) { item in
                            LiveRiverRow(
                                site: item.site,
                                suggestion: item.suggestion,
                                totalTime: item.entry.totalTime,
                                onClassify: { classification in
                                    engine.siteObserver.classify(site: item.site, as: classification)
                                    engine.objectWillChange.send()
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: 160)
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

    private var phaseColor: Color { notchDropdownPhaseColor(engine: engine) }
}

// MARK: - Wing Shape (notch側が直角、外側が角丸)

enum WingSide { case left, right }

struct WingShape: Shape {
    let side: WingSide

    func path(in rect: CGRect) -> Path {
        // notchの裏に隠れる部分は直角でOK。見える外側だけ角丸。
        // notchの物理角丸 ≈ 7pt
        let cornerRadius: CGFloat = 7
        var path = Path()
        switch side {
        case .left:
            // 左上を角丸、他は直角（右側はnotchの裏に隠れる）
            path.move(to: CGPoint(x: cornerRadius, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: cornerRadius, y: rect.maxY))
            path.addArc(
                center: CGPoint(x: cornerRadius, y: rect.maxY - cornerRadius),
                radius: cornerRadius,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: 0, y: cornerRadius))
            path.addArc(
                center: CGPoint(x: cornerRadius, y: cornerRadius),
                radius: cornerRadius,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false
            )
        case .right:
            // 右上を角丸、他は直角（左側はnotchの裏に隠れる）
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: 0))
            path.addArc(
                center: CGPoint(x: rect.maxX - cornerRadius, y: cornerRadius),
                radius: cornerRadius,
                startAngle: .degrees(270),
                endAngle: .degrees(0),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
            path.addArc(
                center: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY - cornerRadius),
                radius: cornerRadius,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: 0, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Live River Row (SiteObserverベース、スライドトグル)

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

            // FLOW/DRIFTスライドトグル
            SlideToggle(isFlow: isFlow, isDrift: isDrift) {
                onClassify(isFlow ? .drift : .flow)
            }
        }
        .padding(.vertical, 1)
    }

    private var barColor: Color {
        if isFlow { return Color.sitboneFlow }
        if isDrift { return Color.sitboneDrift }
        return .white
    }
}

private func notchDropdownCounterItem(_ symbol: String, _ count: Int, _ color: Color) -> some View {
    HStack(spacing: 2) {
        Text(symbol)
            .font(.system(size: 9))
            .foregroundStyle(color)
        Text("\(count)")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.7))
    }
}

@MainActor
private func notchDropdownPhaseColor(engine: SessionEngine) -> Color {
    engine.focusState?.phase.color ?? .gray
}

// MARK: - Slide Toggle (F/D セグメント + スライドインジケータ)

struct SlideToggle: View {
    let isFlow: Bool
    let isDrift: Bool
    let action: () -> Void

    private let cellWidth: CGFloat = 18
    private let cellHeight: CGFloat = 14

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                // スライドするインジケータ背景
                if isFlow || isDrift {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(indicatorColor.opacity(0.15))
                        .frame(width: cellWidth, height: cellHeight)
                        .offset(x: isFlow ? 0 : cellWidth)
                }

                // F / D ラベル
                HStack(spacing: 0) {
                    Text("F")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(isFlow ? Color.sitboneFlow : .white.opacity(0.15))
                        .frame(width: cellWidth, height: cellHeight)
                    Text("D")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(isDrift ? Color.sitboneDrift : .white.opacity(0.15))
                        .frame(width: cellWidth, height: cellHeight)
                }
            }
            .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.04)))
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFlow)
        }
        .buttonStyle(.plain)
    }

    private var indicatorColor: Color {
        isFlow ? Color.sitboneFlow : Color.sitboneDrift
    }
}

// MARK: - Ghost Teacher Banner (notch下にぴょこっと出る)

struct GhostTeacherBanner: View {
    @ObservedObject var engine: SessionEngine
    var onReposition: (() -> Void)?
    @State private var visible = false
    @State private var autoDismissTask: Task<Void, Never>?

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
                        cancelAutoDismiss()
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
                        cancelAutoDismiss()
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
                        cancelAutoDismiss()
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
                    scheduleAutoDismiss()
                }
                .onChange(of: engine.pendingGhostTeacher) { _, newSite in
                    if newSite != nil {
                        // フォーカスディスプレイに再配置してからアニメーション
                        onReposition?()
                        visible = false
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7).delay(0.15)) {
                            visible = true
                        }
                        scheduleAutoDismiss()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scheduleAutoDismiss() {
        cancelAutoDismiss()
        let delay = engine.ghostTeacherAutoDismissSeconds
        guard delay > 0 else { return }
        autoDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) {
                visible = false
            }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            engine.dismissGhostTeacher()
        }
    }

    private func cancelAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
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
    let hours = Int(interval) / 3600
    let minutes = (Int(interval) % 3600) / 60
    let seconds = Int(interval) % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
    return String(format: "%d:%02d", minutes, seconds)
}

/// プロファイルカラー × フェーズ → 表示色
func profilePhaseColor(phase: FocusPhase?, hue: Double) -> Color {
    switch phase {
    case .flow: Color(hue: hue, saturation: 0.7, brightness: 0.9)
    case .drift: Color(hue: hue, saturation: 0.5, brightness: 0.5)
    case .away, nil: .gray
    }
}

/// Ghost Teacherパネル位置計算
func ghostPanelFrame(screenFrame: CGRect, safeTop: CGFloat, width: CGFloat = 280, height: CGFloat = 64) -> NSRect {
    let topY = screenFrame.maxY - safeTop
    let originX = screenFrame.midX - width / 2
    let originY = topY - height - 6
    return NSRect(x: originX, y: originY, width: width, height: height)
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

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

// MARK: - NSEvent + KeyBinding マッチング

extension NSEvent {
    /// KeyBindingの keyCode / modifierFlags と一致するか判定
    func matches(_ binding: KeyBinding) -> Bool {
        guard self.keyCode == binding.keyCode else { return false }
        // 比較対象の修飾キーマスク（deviceIndependentFlagsMask相当）
        let relevant: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        let eventMods = self.modifierFlags.intersection(relevant)
        let bindingMods = NSEvent.ModifierFlags(rawValue: UInt(binding.modifierFlags)).intersection(relevant)
        return eventMods == bindingMods
    }
}
