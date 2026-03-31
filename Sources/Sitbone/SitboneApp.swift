import SwiftUI
import AppKit
import SitboneCore
import SitboneUI
import SitboneData

@main
struct SitboneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var engine = SessionEngine(deps: .live)

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(engine: engine)
                .onAppear {
                    appDelegate.setupNotch(engine: engine)
                }
                .onChange(of: engine.isSessionActive) { _, active in
                    if active {
                        appDelegate.notchController?.show()
                    } else {
                        appDelegate.notchController?.hide()
                    }
                }
        } label: {
            let phase = engine.focusState?.phase
            Image(nsImage: menuBarIcon(phase: phase))
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - AppDelegate (二重起動防止 + Notch管理)

final class AppDelegate: NSObject, NSApplicationDelegate {
    var notchController: NotchOverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
    }

    @MainActor
    func setupNotch(engine: SessionEngine) {
        guard notchController == nil else { return }
        notchController = NotchOverlayController(engine: engine)
    }
}
