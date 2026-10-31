import SwiftUI

struct MachinesView: View {
    @Environment(AppStore.self) private var store
    @State private var showingNew = false

    /// Machines being created don't appear in `colima list` until they boot, so show a placeholder.
    private var pendingNames: [String] {
        store.busy
            .filter { $0.value == "Creating…" && !store.machines.map(\.name).contains($0.key) }
            .map(\.key)
            .sorted()
    }

    var body: some View {
        Group {
            if store.colimaMissing {
                ContentUnavailableView {
                    Label("Colima isn't installed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Install it with Homebrew, then reopen this window.")
                    Text("brew install colima docker").font(.body.monospaced()).textSelection(.enabled)
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
                            MachineCard(machine: machine)
                        }
                        ForEach(pendingNames, id: \.self) { name in
                            PendingMachineCard(name: name)
                        }
                    }
                    .padding(20)
                }
            }
        }
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
        .sheet(isPresented: $showingNew) {
            NewMachineSheet()
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
    @State private var confirmingDelete = false

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
                spec("cpu", "\(machine.cpus)", "CPUs")
                spec("memorychip", machine.memory.gib, "Memory")
                spec("internaldrive", machine.disk.gib, "Disk")
                spec("cpu.fill", machine.arch, "Arch")
            }

            if !machine.address.isEmpty {
                Label(machine.address, systemImage: "network")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Divider()

            HStack {
                if machine.isRunning {
                    Button("Stop") { store.stop(machine) }
                    Button("Restart") { store.restart(machine) }
                } else {
                    Button("Start") { store.start(machine) }
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
                if isTarget && store.machines.count > 1 {
                    Text("Shown in Docker views")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                menu
            }
            .disabled(busyLabel != nil)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isTarget && store.machines.count > 1 ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        .confirmationDialog("Delete \(machine.name)?", isPresented: $confirmingDelete) {
            Button("Delete Machine", role: .destructive) { store.delete(machine, includeData: false) }
            Button("Delete Machine and Container Data", role: .destructive) { store.delete(machine, includeData: true) }
        } message: {
            Text("The VM and its settings are removed. Choose whether to also remove images, containers and volumes stored for this machine.")
        }
    }

    private var menu: some View {
        Menu {
            Button("Open Terminal") { store.openShell(machine) }
                .disabled(!machine.isRunning)
            Button("Edit Settings File") { store.openConfig(machine) }
            Button("Show in Docker Views") { store.selectMachine(machine.name) }
                .disabled(isTarget)
            Divider()
            if machine.isRunning {
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

    private func spec(_ symbol: String, _ value: String, _ label: String) -> some View {
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

struct NewMachineSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var config = MachineConfig()

    private let maxCPUs = ProcessInfo.processInfo.activeProcessorCount
    private let maxMemory = max(2, Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824))

    private var defaultName: String { store.machines.isEmpty ? "default" : "dev" }
    private var effectiveName: String { config.name.isEmpty ? defaultName : config.name }

    private var nameProblem: String? {
        let name = effectiveName
        if name.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) == nil {
            return "Use lowercase letters, numbers and dashes."
        }
        if store.machines.contains(where: { $0.name == name }) { return "A machine with this name already exists." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $config.name, prompt: Text(defaultName))
                    if let nameProblem {
                        Text(nameProblem).font(.caption).foregroundStyle(.red)
                    }
                }

                Section("Resources") {
                    Stepper("CPUs: \(config.cpus)", value: $config.cpus, in: 1...maxCPUs)
                    Stepper("Memory: \(config.memoryGiB) GiB", value: $config.memoryGiB, in: 1...maxMemory)
                    Stepper("Disk: \(config.diskGiB) GiB", value: $config.diskGiB, in: 10...1000, step: 10)
                }

                Section("Runtime") {
                    Picker("Container runtime", selection: $config.runtime) {
                        Text("Docker").tag("docker")
                        Text("containerd").tag("containerd")
                        Text("Incus").tag("incus")
                    }
                    Toggle("Kubernetes (k3s)", isOn: $config.kubernetes)
                }

                Section("Virtual machine") {
                    Picker("Type", selection: $config.vmType) {
                        Text("Apple Virtualization (vz)").tag("vz")
                        Text("QEMU").tag("qemu")
                    }
                    if config.vmType == "vz" {
                        Toggle("Use Rosetta for Intel images", isOn: $config.rosetta)
                    }
                    Toggle("Give the VM its own IP address", isOn: $config.networkAddress)
                }
            }
            .formStyle(.grouped)

            HStack {
                Text("The first start downloads a VM image, so it can take a few minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    config.name = effectiveName
                    store.create(config)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(nameProblem != nil)
            }
            .padding(16)
        }
        .frame(width: 480, height: 560)
    }
}
