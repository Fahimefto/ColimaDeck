import SwiftUI

struct MachineDetailView: View {
    @Environment(AppStore.self) private var store
    let name: String

    @State private var status: [(key: String, value: String)] = []
    @State private var version = ""
    @State private var sshConfig = ""
    @State private var settings = MachineConfig()
    @State private var editing: MachineConfig?
    @State private var confirmingDelete = false

    private var machine: Machine? { store.machines.first { $0.name == name } }

    var body: some View {
        if let machine {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(machine)
                    details(machine)
                    KubernetesBox(machine: machine, enabled: settings.kubernetes)
                    CommandBox(machine: machine)
                    RuntimeBox(machine: machine, version: version)
                    ModelsBox(machine: machine, vmType: settings.vmType)
                    sshBox(machine)
                }
                .padding(20)
                .frame(maxWidth: 900, alignment: .leading)
            }
            .navigationTitle(machine.name)
            .task(id: "\(machine.status)|\(machine.runtime)") { await load(machine) }
            .machineDialogs(machine: machine, editing: $editing, confirmingDelete: $confirmingDelete)
        } else {
            ContentUnavailableView("Machine not found", systemImage: "desktopcomputer",
                                   description: Text("\(name) may have been deleted."))
        }
    }

    private func load(_ machine: Machine) async {
        settings = store.settings(for: machine)
        status = machine.isRunning ? await store.status(of: machine) : []
        version = await store.version(of: machine)
        sshConfig = machine.isRunning ? await store.sshConfig(for: machine) : ""
    }

    private func header(_ machine: Machine) -> some View {
        let busy = store.busy[machine.name]
        return HStack(spacing: 10) {
            StatusDot(machine: machine, busy: busy != nil)
            Text(busy ?? machine.status)
                .foregroundStyle(busy != nil ? .orange : machine.isRunning ? .green : .secondary)
            if !machine.runtime.isEmpty { Pill(text: machine.runtime, tint: .accentColor) }
            Spacer()
            Group {
                if machine.isRunning {
                    Button("Open Terminal") { store.openShell(machine) }
                    Button("Stop") { store.stop(machine) }
                    Button("Restart") { store.restart(machine) }
                } else {
                    Button("Start") { store.start(machine) }
                        .buttonStyle(.borderedProminent)
                }
                Button("Edit Settings…") { editing = store.settings(for: machine) }
                MachineMenu(machine: machine, editing: $editing, confirmingDelete: $confirmingDelete)
            }
            .disabled(busy != nil)
        }
    }

    private func details(_ machine: Machine) -> some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                if status.isEmpty {
                    row("CPUs", "\(machine.cpus)")
                    row("Memory", machine.memory.gib)
                    row("Disk", machine.disk.gib)
                    row("Architecture", machine.arch)
                    row("VM type", settings.vmType)
                    row("Runtime", settings.runtime)
                    row("Kubernetes", settings.kubernetes ? "On" : "Off")
                } else {
                    ForEach(status, id: \.key) { item in row(item.key, item.value) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            boxLabel("Details", note: status.isEmpty && !machine.isRunning ? "Start the machine for live details." : nil)
        }
    }

    private func sshBox(_ machine: Machine) -> some View {
        GroupBox {
            if sshConfig.isEmpty {
                Text(machine.isRunning ? "Loading…" : "Start the machine to see how to connect over SSH.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            } else {
                OutputText(text: sshConfig)
            }
        } label: {
            HStack {
                boxLabel("SSH connection", note: "For tools that connect over SSH, like VS Code Remote.")
                Spacer()
                if !sshConfig.isEmpty {
                    Button("Copy") { copy(sshConfig) }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(3)
        }
    }
}

// MARK: - Boxes

private struct KubernetesBox: View {
    @Environment(AppStore.self) private var store
    let machine: Machine
    let enabled: Bool
    @State private var confirming: String?

    var body: some View {
        GroupBox {
            HStack {
                Button("Start") { store.kubernetes(machine, "start") }
                Button("Stop") { store.kubernetes(machine, "stop") }
                Button("Reset…") { confirming = "reset" }
                Button("Delete…") { confirming = "delete" }
                Spacer()
            }
            .disabled(!machine.isRunning || store.busy[machine.name] != nil)
            .padding(6)
        } label: {
            boxLabel("Kubernetes", note: machine.isRunning
                     ? (enabled ? "Kubernetes is turned on for this machine." : "Kubernetes is turned off in this machine's settings.")
                     : "Start the machine to manage Kubernetes.")
        }
        .confirmationDialog(confirming == "reset" ? "Reset Kubernetes?" : "Delete Kubernetes?",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button(confirming == "reset" ? "Reset" : "Delete", role: .destructive) {
                if let verb = confirming { store.kubernetes(machine, verb) }
            }
        } message: {
            Text(confirming == "reset"
                 ? "The cluster is deleted and created again, empty. Everything deployed to it is lost."
                 : "The cluster and everything deployed to it are deleted.")
        }
    }
}

private struct CommandBox: View {
    @Environment(AppStore.self) private var store
    let machine: Machine
    @State private var command = ""
    @State private var result: CommandResult?
    @State private var running = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Command", text: $command, prompt: Text("uname -a"))
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .onSubmit(run)
                    Button("Run", action: run)
                        .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty || running)
                    if running { ProgressView().controlSize(.small) }
                }
                if let result {
                    OutputText(text: [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n"),
                               failed: !result.ok)
                }
            }
            .disabled(!machine.isRunning)
            .padding(6)
        } label: {
            boxLabel("Run a command", note: machine.isRunning ? "Runs inside the VM. For anything interactive, use Open Terminal." : "Start the machine to run commands in it.")
        }
    }

    private func run() {
        let text = command.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !running else { return }
        running = true
        Task {
            result = await store.run(text, in: machine)
            running = false
        }
    }
}

private struct RuntimeBox: View {
    @Environment(AppStore.self) private var store
    let machine: Machine
    let version: String
    @State private var nerdctlPath = "/usr/local/bin/nerdctl"
    @State private var replaceNerdctl = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if !version.isEmpty { OutputText(text: version) }
                HStack {
                    Button("Update Container Runtime") { store.updateRuntime(machine) }
                        .disabled(!machine.isRunning || store.busy[machine.name] != nil)
                    Spacer()
                }
                if machine.runtime.hasPrefix("containerd") {
                    Divider()
                    Text("nerdctl").font(.headline)
                    Text("containerd machines use nerdctl instead of docker. Install a `nerdctl` command on your Mac that runs it in this machine.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("Install at", text: $nerdctlPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                        Toggle("Replace existing", isOn: $replaceNerdctl)
                        Button("Install") { store.installNerdctl(for: machine, path: nerdctlPath, force: replaceNerdctl) }
                            .disabled(store.busy["nerdctl"] != nil)
                    }
                    Button("Open nerdctl in Terminal") { store.openNerdctl(machine) }
                }
            }
            .padding(6)
        } label: {
            boxLabel("Runtime and versions", note: machine.isRunning ? nil : "Start the machine to see runtime versions or update them.")
        }
    }
}

private struct ModelsBox: View {
    @Environment(AppStore.self) private var store
    let machine: Machine
    let vmType: String
    @State private var model = ""
    @State private var list: CommandResult?

    private var supported: Bool { machine.usesDocker && vmType == "krunkit" }
    private var busy: String? { store.busy["model:\(machine.name)"] }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Set Up") { store.setUpModels(machine) }
                    Button("Show Models") { Task { list = await store.listModels(machine) } }
                    if let busy {
                        ProgressView().controlSize(.small)
                        Text(busy).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack {
                    TextField("Model", text: $model, prompt: Text("tinyllama"))
                        .textFieldStyle(.roundedBorder)
                    Button("Pull") { store.pullModel(model, on: machine) }
                    Button("Chat") { store.openModel(model, on: machine, verb: "run") }
                    Button("Serve") { store.openModel(model, on: machine, verb: "serve") }
                }
                .disabled(model.trimmingCharacters(in: .whitespaces).isEmpty)
                if let list {
                    OutputText(text: list.ok ? list.stdout : list.message, failed: !list.ok)
                }
            }
            .disabled(!machine.isRunning || !supported || busy != nil)
            .padding(6)
        } label: {
            boxLabel("AI models", note: supported
                     ? "Run AI models in the VM with GPU access. Chat and Serve open in Terminal."
                     : "Needs a machine with the Docker runtime and the krunkit VM type.")
        }
    }
}

// MARK: - Shared pieces

struct OutputText: View {
    let text: String
    var failed = false

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "No output." : text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(failed ? .red : text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }
}

private func boxLabel(_ title: String, note: String?) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.headline)
        if let note {
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }
    .padding(.bottom, 4)
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
