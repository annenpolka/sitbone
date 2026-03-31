import SwiftUI
import AppKit
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

        // Notchオーバーレイ + セッション起動
        Task { @MainActor in
            let controller = NotchOverlayController(engine: engine)
            self.notchController = controller
            controller.show()

            // --auto-start フラグまたはデバッグビルドで自動セッション開始
            #if DEBUG
            let autoStart = true
            #else
            let autoStart = CommandLine.arguments.contains("--auto-start")
            #endif

            if autoStart {
                engine.startSession()
            }
        }
    }
}
