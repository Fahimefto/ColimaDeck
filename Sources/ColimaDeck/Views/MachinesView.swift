import SwiftUI

struct MachinesView: View {
    @Environment(AppStore.self) private var store
    @State private var path: [String] = []
    @State private var showingNew = false
    @State private var showingSetup = false

    /// Machines being created don't appear in `colima list` until they boot, so show a placeholder.
    private var pendingNames: [String] {
        store.busy
            .filter { $0.value == "Creating…" && !store.machines.map(\.name).contains($0.key) }
            .map(\.key)
            .sorted()
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Machines")
                .navigationSubtitle(subtitle)
                .toolbar {
                    ToolbarItem {
                        Button {
                            showingNew = true
                        } label: {
                            Label("New Machine", systemImage: "plus")
                        }
                        .help("Create a new machine")
                    }
                }
                .navigationDestination(for: String.self) { name in
                    MachineDetailView(name: name)
                }
        }
        .sheet(isPresented: $showingSetup) { SetupView() }
        .sheet(isPresented: $showingNew) {
            MachineSettingsSheet(mode: .create, original: store.templateSettings())
        }
    }

    @ViewBuilder private var content: some View {
        if store.colimaMissing {
            ContentUnavailableView {
                Label("Colima isn't installed", systemImage: "exclamationmark.triangle")
            } description: {
                Text("ColimaDeck can install it for you.")
            } actions: {
                Button("Set Up…") { showingSetup = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if store.machinesLoaded && store.machines.isEmpty && pendingNames.isEmpty {
            ContentUnavailableView {
                Label("No machines yet", systemImage: "desktopcomputer")
            } description: {
                Text("A machine is a small Linux VM that runs your containers.")
            } actions: {
                Button("Create Machine") { showingNew = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                    ForEach(store.machines) { machine in
                        MachineCard(machine: machine) { path.append(machine.name) }
                    }
                    ForEach(pendingNames, id: \.self) { name in
                        PendingMachineCard(name: name)
                    }
                }
                .padding(20)
            }
        }
    }

    private var subtitle: String {
        let total = store.machines.count
        return total == 0 ? "" : "\(store.runningCount) of \(total) running"
    }
}

private struct MachineCard: View {
    @Environment(AppStore.self) private var store
    let machine: Machine
    let showDetails: () -> Void
    @State private var confirmingDelete = false
    @State private var editing: MachineConfig?

    private var busyLabel: String? { store.busy[machine.name] }
    private var isTarget: Bool { store.selectedMachineName == machine.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                StatusDot(machine: machine, busy: busyLabel != nil)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                VStack(alignment: .leading, spacing: 2) {
                    Text(machine.name).font(.title3.weight(.semibold))
                    Text(busyLabel ?? machine.status)
                        .font(.callout)
                        .foregroundStyle(busyLabel != nil ? .orange : machine.isRunning ? .green : .secondary)
                }
                Spacer()
                if !machine.runtime.isEmpty {
                    Pill(text: machine.runtime, tint: .accentColor)
                }
            }

            HStack(spacing: 0) {
                spec("\(machine.cpus)", "CPUs")
                spec(machine.memory.gib, "Memory")
                spec(machine.disk.gib, "Disk")
                spec(machine.arch, "Arch")
            }

            if !machine.address.isEmpty {
                Label(machine.address, systemImage: "network")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Divider()

            HStack {
                Group {
                    if machine.isRunning {
                        Button("Stop") { store.stop(machine) }
                        Button("Restart") { store.restart(machine) }
                    } else {
                        Button("Start") { store.start(machine) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .disabled(busyLabel != nil)
                Spacer()
                if isTarget && store.machines.count > 1 {
                    Text("Shown in Docker views")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                MachineMenu(machine: machine, editing: $editing, confirmingDelete: $confirmingDelete)
                    .disabled(busyLabel != nil)
                Button("Details", action: showDetails)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isTarget && store.machines.count > 1 ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(count: 2, perform: showDetails)
        .machineDialogs(machine: machine, editing: $editing, confirmingDelete: $confirmingDelete)
    }

    private func spec(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The "⋯" menu shared by machine cards and the details page.
struct MachineMenu: View {
    @Environment(AppStore.self) private var store
    let machine: Machine
    @Binding var editing: MachineConfig?
    @Binding var confirmingDelete: Bool

    var body: some View {
        Menu {
            Button("Edit Settings…") { editing = store.settings(for: machine) }
            Button("Open Terminal") { store.openShell(machine) }
                .disabled(!machine.isRunning)
            Button("Show in Docker Views") { store.selectMachine(machine.name) }
                .disabled(store.selectedMachineName == machine.name)
            Divider()
            Menu("Kubernetes") {
                Button("Start") { store.kubernetes(machine, "start") }
                Button("Stop") { store.kubernetes(machine, "stop") }
                Button("Reset") { store.kubernetes(machine, "reset") }
                Button("Delete") { store.kubernetes(machine, "delete") }
            }
            .disabled(!machine.isRunning)
            Button("Update Container Runtime") { store.updateRuntime(machine) }
                .disabled(!machine.isRunning)
            Divider()
            if machine.isRunning {
                Button("Force Restart") { store.restart(machine, force: true) }
                Button("Force Stop") { store.stop(machine, force: true) }
            }
            Button("Delete…", role: .destructive) { confirmingDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions for \(machine.name)")
    }
}

extension View {
    /// The settings sheet and delete confirmation that go with `MachineMenu`.
    func machineDialogs(machine: Machine, editing: Binding<MachineConfig?>, confirmingDelete: Binding<Bool>) -> some View {
        modifier(MachineDialogs(machine: machine, editing: editing, confirmingDelete: confirmingDelete))
    }
}

private struct MachineDialogs: ViewModifier {
    @Environment(AppStore.self) private var store
    let machine: Machine
    @Binding var editing: MachineConfig?
    @Binding var confirmingDelete: Bool

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { editing.map { IdentifiedConfig(config: $0) } },
                set: { editing = $0?.config }
            )) { item in
                MachineSettingsSheet(mode: .edit(machine), original: item.config)
            }
            .confirmationDialog("Delete \(machine.name)?", isPresented: $confirmingDelete) {
                Button("Delete Machine", role: .destructive) { store.delete(machine, includeData: false) }
                Button("Delete Machine and Container Data", role: .destructive) { store.delete(machine, includeData: true) }
            } message: {
                Text("The VM and its settings are removed. Choose whether to also remove images, containers and volumes stored for this machine.")
            }
    }
}

private struct IdentifiedConfig: Identifiable {
    let config: MachineConfig
    var id: String { config.name }
}

private struct PendingMachineCard: View {
    let name: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.title3.weight(.semibold))
                Text("Creating… this can take a few minutes the first time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .frame(minHeight: 120)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)) }
    }
}
