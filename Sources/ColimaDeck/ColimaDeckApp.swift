import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keep the menu bar item alive
    }
}

@main
struct ColimaDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore()

    var body: some Scene {
        Window("ColimaDeck", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 920, minHeight: 580)
                .task { store.startPolling() }
        }
        .defaultSize(width: 1120, height: 720)

        MenuBarExtra {
            MenuBarView()
                .environment(store)
        } label: {
            Image(systemName: store.runningCount > 0 ? "shippingbox.fill" : "shippingbox")
        }
    }
}
