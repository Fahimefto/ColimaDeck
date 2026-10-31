import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: SidebarItem? = .machines
    @State private var showingSetup = false
    @State private var checkedSetup = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Colima") {
                    row(.machines, badge: store.runningCount)
                    row(.tools)
                }
                Section("Docker") {
                    row(.containers, badge: store.containers.filter(\.isRunning).count)
                    row(.images)
                    row(.volumes)
                }
                Section {
                    row(.activity, badge: store.activity.filter { $0.state == .running }.count)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            switch selection ?? .machines {
            case .machines: MachinesView()
            case .containers: ContainersView()
            case .images: ImagesView()
            case .volumes: VolumesView()
            case .tools: ToolsView()
            case .activity: ActivityView()
            }
        }
        .sheet(isPresented: $showingSetup) { SetupView() }
        .onChange(of: store.machinesLoaded) {
            // Offer to install missing tools once, after the first check.
            guard store.machinesLoaded, !checkedSetup else { return }
            checkedSetup = true
            showingSetup = store.colimaMissing || store.dockerMissing
        }
        .alert("Something went wrong", isPresented: alertBinding) {
            Button("OK") {}
            Button("Show Activity") { selection = .activity }
        } message: {
            Text(store.alert ?? "")
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })
    }

    private func row(_ item: SidebarItem, badge: Int = 0) -> some View {
        Label(item.title, systemImage: item.symbol)
            .badge(badge)
            .tag(item)
    }
}

/// Shows which machine the Docker views are pointed at.
private struct SidebarFooter: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let machine = store.selectedMachine {
            HStack(spacing: 8) {
                StatusDot(machine: machine, busy: store.busy[machine.name] != nil)
                VStack(alignment: .leading, spacing: 1) {
                    Text(machine.name).font(.callout.weight(.medium))
                    Text(store.busy[machine.name] ?? machine.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}
