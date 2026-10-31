import SwiftUI

struct MenuBarView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if store.machines.isEmpty {
            Text(store.colimaMissing ? "Colima isn't installed" : "No machines")
        }
        ForEach(store.machines) { machine in
            if let label = store.busy[machine.name] {
                Text("\(machine.name) — \(label)")
            } else if machine.isRunning {
                Button("Stop \(machine.name)") { store.stop(machine) }
            } else {
                Button("Start \(machine.name)") { store.start(machine) }
            }
        }

        let running = store.containers.filter(\.isRunning)
        if !running.isEmpty {
            Divider()
            Text("\(running.count) containers running")
        }

        Divider()
        Button("Open ColimaDeck") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
