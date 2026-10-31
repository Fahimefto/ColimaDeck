import SwiftUI

/// Creates a machine, edits an existing one's settings, or edits the template for new machines.
/// Covers every `colima start` option.
struct MachineSettingsSheet: View {
    enum Mode {
        case create
        case edit(Machine)
        case template(exists: Bool)
    }

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    private let original: MachineConfig
    @State private var config: MachineConfig

    private let maxCPUs = ProcessInfo.processInfo.activeProcessorCount
    private let maxMemory = max(2.0, Double(ProcessInfo.processInfo.physicalMemory / 1_073_741_824))

    /// `original` is the settings the form starts from: the machine's, or the template's.
    init(mode: Mode, original: MachineConfig? = nil) {
        self.mode = mode
        self.original = original ?? MachineConfig()
        _config = State(initialValue: original ?? MachineConfig())
    }

    private var machine: Machine? {
        if case .edit(let machine) = mode { return machine }
        return nil
    }

    private var isCreating: Bool {
        if case .create = mode { return true }
        return false
    }

    /// Settings that can't change once a machine exists are locked when editing one.
    private var isEditing: Bool { machine != nil }

    private var hasChanges: Bool {
        if case .template(exists: false) = mode { return true }
        return config != original
    }
    private var defaultName: String { store.machines.isEmpty ? "default" : "dev" }
    private var effectiveName: String { config.name.isEmpty ? defaultName : config.name }

    private var nameProblem: String? {
        guard isCreating else { return nil }
        if effectiveName.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) == nil {
            return "Use lowercase letters, numbers and dashes."
        }
        if store.machines.contains(where: { $0.name == effectiveName }) { return "A machine with this name already exists." }
        return nil
    }

    private var createArguments: [String] {
        var named = config
        named.name = effectiveName
        return named.createArguments(template: store.templateSettings())
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if isCreating {
                    Section {
                        TextField("Name", text: $config.name, prompt: Text(defaultName))
                        if let nameProblem {
                            Text(nameProblem).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                resources
                runtime
                virtualMachine
                folders
                network
                dns
                ssh
                environment
                if isCreating { settingsFiles }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 580, height: 720)
    }

    // MARK: Sections

    private var resources: some View {
        Section("Resources") {
            Stepper("CPUs: \(config.cpus)", value: $config.cpus, in: 1...maxCPUs)
            Stepper("Memory: \(config.memoryGiB.formatted()) GiB", value: $config.memoryGiB, in: 0.5...maxMemory, step: 0.5)
            Stepper("Disk for containers: \(config.diskGiB) GiB", value: $config.diskGiB,
                    in: (isEditing ? original.diskGiB : 10)...2000, step: 10)
            if isEditing {
                note("Disk size can only grow once a machine exists.")
            } else {
                Stepper("Disk for the system: \(config.rootDiskGiB) GiB", value: $config.rootDiskGiB, in: 5...500, step: 5)
                Picker("Architecture", selection: $config.arch) {
                    Text("ARM (aarch64)").tag("aarch64")
                    Text("Intel (x86_64)").tag("x86_64")
                }
                if config.arch != MachineConfig.hostArch {
                    note("A different architecture than your Mac is emulated, which is much slower.")
                }
                pathField("Custom disk image", text: $config.diskImage, prompt: "Colima's standard image")
            }
        }
    }

    private var runtime: some View {
        Section("Runtime") {
            Picker("Container runtime", selection: $config.runtime) {
                Text("Docker").tag("docker")
                Text("containerd").tag("containerd")
                Text("Incus").tag("incus")
            }
            .disabled(isEditing)
            Toggle("Make it the active context when it starts", isOn: $config.activate)
            Toggle("Kubernetes (k3s)", isOn: $config.kubernetes)
            if config.kubernetes {
                TextField("Kubernetes version", text: $config.kubernetesVersion, prompt: Text("Colima's default"))
                numberField("k3s listen port", value: $config.k3sListenPort, prompt: "Automatic")
                ListEditor(title: "k3s arguments", placeholder: "--disable=traefik", items: $config.k3sArgs)
            }
        }
    }

    private var virtualMachine: some View {
        Section("Virtual machine") {
            Picker("Type", selection: $config.vmType) {
                Text("Apple Virtualization (vz)").tag("vz")
                Text("QEMU").tag("qemu")
                Text("krunkit (GPU access)").tag("krunkit")
            }
            .disabled(isEditing)
            .onChange(of: config.vmType) {
                // virtiofs only works with Apple Virtualization and krunkit.
                if config.vmType == "qemu" && config.mountType == "virtiofs" { config.mountType = "sshfs" }
            }
            if config.vmType == "vz" {
                Toggle("Use Rosetta for Intel images", isOn: $config.rosetta)
                Toggle("Allow nested virtualization (M3 or later)", isOn: $config.nestedVirtualization)
            }
            if config.vmType == "qemu" {
                TextField("CPU type", text: $config.cpuType, prompt: Text("Automatic"))
            }
            Toggle("Run images for other architectures (binfmt)", isOn: $config.binfmt)
            TextField("Hostname", text: $config.hostname, prompt: Text("colima"))
        }
    }

    private var folders: some View {
        Section("Shared folders") {
            if isCreating {
                Toggle("Don't share any folders", isOn: $config.disableMounts)
            }
            if !config.disableMounts {
                ForEach($config.mounts) { $mount in
                    HStack {
                        TextField("Folder", text: $mount.path).labelsHidden()
                        Toggle("Writable", isOn: $mount.writable)
                        removeButton { config.mounts.removeAll { $0.id == mount.id } }
                    }
                }
                Button("Add Folder…") {
                    if let path = choosePath(directories: true) {
                        config.mounts.append(.init(path: path, writable: true))
                    }
                }
                if config.mounts.isEmpty {
                    note("With no folders listed, Colima shares its default folders.")
                }
                Picker("Sharing method", selection: $config.mountType) {
                    Text("virtiofs").tag("virtiofs")
                    Text("sshfs").tag("sshfs")
                    Text("9p").tag("9p")
                }
                Toggle("Pass file change events to containers", isOn: $config.mountInotify)
            }
        }
    }

    private var network: some View {
        Section("Network") {
            Toggle("Give the VM its own IP address", isOn: $config.networkAddress)
            if config.networkAddress {
                Picker("Mode", selection: $config.networkMode) {
                    Text("Shared").tag("shared")
                    Text("Bridged").tag("bridged")
                }
                if config.networkMode == "bridged" {
                    TextField("Network interface", text: $config.networkInterface, prompt: Text("en0"))
                }
                Toggle("Prefer the VM's own IP address for traffic", isOn: $config.networkPreferredRoute)
            }
            Toggle("Allow forwarding ports to specific host addresses", isOn: $config.networkHostAddresses)
            TextField("Gateway address", text: $config.gatewayAddress, prompt: Text("192.168.5.2"))
            Picker("Port forwarding", selection: $config.portForwarder) {
                Text("SSH").tag("ssh")
                Text("gRPC").tag("grpc")
                Text("Off").tag("none")
            }
        }
    }

    private var dns: some View {
        Section("DNS") {
            ListEditor(title: "DNS servers", placeholder: "1.1.1.1", items: $config.dns)
            ListEditor(title: "Custom names", placeholder: "example.test=192.168.5.2", items: $config.dnsHosts)
        }
    }

    private var ssh: some View {
        Section("SSH") {
            Toggle("Forward your SSH agent into the VM", isOn: $config.sshAgent)
            Toggle("Add the VM to ~/.ssh/config", isOn: $config.sshConfig)
            numberField("SSH port", value: $config.sshPort, prompt: "Automatic")
        }
    }

    private var environment: some View {
        Section("Environment variables") {
            ListEditor(title: "Variables", placeholder: "KEY=value", items: $config.env)
        }
    }

    private var settingsFiles: some View {
        Section("Settings files") {
            Toggle("Start from the template for new machines", isOn: $config.useTemplate)
            Toggle("Remember these settings for next time it starts", isOn: $config.saveConfig)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isCreating {
                Text("colima " + createArguments.joined(separator: " "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text(footerNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                switch mode {
                case .create:
                    Button("Create") {
                        config.name = effectiveName
                        store.create(config)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(nameProblem != nil)
                case .edit(let machine):
                    Button("Save") { save(machine, andApply: false) }
                        .disabled(!hasChanges)
                    Button(machine.isRunning ? "Save and Restart" : "Save and Start") { save(machine, andApply: true) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!hasChanges)
                case .template:
                    Button("Save Template") {
                        store.saveTemplate(config, original: original)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges)
                }
            }
        }
        .padding(16)
    }

    private var footerNote: String {
        switch mode {
        case .create: "The first start downloads a VM image, so it can take a few minutes."
        case .edit(let machine): machine.isRunning ? "Changes take effect when the machine restarts." : "Changes take effect when the machine starts."
        case .template: "New machines start with these settings."
        }
    }

    private func save(_ machine: Machine, andApply: Bool) {
        store.saveSettings(config, for: machine, original: original, andApply: andApply)
        dismiss()
    }

    // MARK: Helpers

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func numberField(_ label: String, value: Binding<Int>, prompt: String) -> some View {
        TextField(label, value: Binding(
            get: { value.wrappedValue == 0 ? nil : value.wrappedValue },
            set: { value.wrappedValue = $0 ?? 0 }
        ), format: .number.grouping(.never), prompt: Text(prompt))
    }

    private func pathField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack {
            TextField(label, text: text, prompt: Text(prompt))
            Button("Choose…") {
                if let path = choosePath(directories: false) { text.wrappedValue = path }
            }
        }
    }

    private func choosePath(directories: Bool) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Remove")
    }
}

/// An editable list of short text values, like DNS servers or environment variables.
struct ListEditor: View {
    let title: String
    let placeholder: String
    @Binding var items: [String]

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(items.indices, id: \.self) { index in
                    HStack {
                        TextField(title, text: Binding(
                            get: { index < items.count ? items[index] : "" },
                            set: { if index < items.count { items[index] = $0 } }
                        ), prompt: Text(placeholder))
                        .labelsHidden()
                        .font(.body.monospaced())
                        Button {
                            if index < items.count { items.remove(at: index) }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove")
                    }
                }
                Button("Add") { items.append("") }
            }
        }
    }
}
