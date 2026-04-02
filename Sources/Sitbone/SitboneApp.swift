import SwiftUI
import AppKit
import ApplicationServices
import SitboneCore
import SitboneUI
import SitboneData

@main
struct SitboneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(engine: appDelegate.engine)
        } label: {
            let phase = appDelegate.engine.focusState?.phase
            Image(nsImage: menuBarIcon(phase: phase))
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let engine = SessionEngine(deps: .live)
    @MainActor var notchController: NotchOverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 二重起動チェック
        let myPID = ProcessInfo.processInfo.processIdentifier
        let myName = ProcessInfo.processInfo.processName
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName == myName
            && $0.processIdentifier != myPID
        }
        if !running.isEmpty {
            running.first?.activate()
            NSApp.terminate(nil)
            return
        }

        // アクセシビリティ権限をリクエスト (ウィンドウタイトル取得に必要)
        requestAccessibilityPermission()

        Task { @MainActor in
            // 永続データをロード
            engine.loadProfiles()
            engine.loadClassifications()
            engine.loadCumulativeData()

            let controller = NotchOverlayController(engine: engine)
            self.notchController = controller
            controller.show()

            #if DEBUG
            let autoStart = true
            #else
            let autoStart = CommandLine.arguments.contains("--auto-start")
            #endif

            // DRIFT効果音 (ADR-0007)
            engine.onDriftEntered = {
                NSSound(named: "Tink")?.play()
            }

            if autoStart {
                engine.startSession()
            }

            // システムスリープ/ウェイク + 画面オフ/オン検知 (ADR-0015)
            let sleepEngine = engine
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
                NSWorkspace.shared.notificationCenter.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { _ in
                    Task { @MainActor in
                        sleepEngine.handleSystemSleep()
                    }
                }
            }
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
                NSWorkspace.shared.notificationCenter.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { _ in
                    Task { @MainActor in
                        sleepEngine.handleSystemWake()
                    }
                }
            }
        }
    }

    private func requestAccessibilityPermission() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
