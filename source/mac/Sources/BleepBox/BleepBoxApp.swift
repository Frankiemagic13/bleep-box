import AppKit
import SwiftUI

struct BleepBoxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("Bleep Box") {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let server = ControlServer()
    private var hotkey: Hotkey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppModel.shared.boot()
        server.start()
        hotkey = Hotkey(onPress: { AppModel.shared.press() },
                        onRelease: { AppModel.shared.release() })
    }

    // Keep running when the window is closed, so the Stream Deck key still works.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.setBleep(false)
        AppModel.shared.stopHelper()
        AppModel.shared.stopAudio()
    }
}
