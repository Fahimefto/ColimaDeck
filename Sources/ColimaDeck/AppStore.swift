import AppKit
import Observation

enum SidebarItem: String, CaseIterable, Identifiable {
    case machines, containers, images, volumes, tools, activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .machines: "Machines"
        case .containers: "Containers"
        case .images: "Images"
        case .volumes: "Volumes"
        case .tools: "Tools"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .machines: "desktopcomputer"
        case .containers: "shippingbox"
        case .images: "square.stack.3d.up"
        case .volumes: "externaldrive"
        case .tools: "wrench.and.screwdriver"
        case .activity: "list.bullet.rectangle"
        }
    }
}

/// How much detail Colima prints for actions, via `--verbose` and `--very-verbose`.
enum Verbosity: String, CaseIterable, Identifiable {
    case normal, verbose, veryVerbose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: "Normal"
        case .verbose: "Verbose"
        case .veryVerbose: "Very verbose"
        }
    }

    var flags: [String] {
        switch self {
        case .normal: []
        case .verbose: ["--verbose"]
        case .veryVerbose: ["--very-verbose"]
        }
    }
}

@MainActor
@Observable
final class AppStore {
    var machines: [Machine] = []
    var machinesLoaded = false
    var colimaMissing = false
    var dockerMissing = false

    /// The machine whose Docker engine the container, image and volume views talk to.
    var selectedMachineName: String?

    var containers: [Container] = []
    var stats: [String: ContainerStats] = [:]
    var images: [DockerImage] = []
    var volumes: [DockerVolume] = []
    var dockerError: String?

    /// Operations in flight, keyed by machine name or container ID, with a label like "Starting…".
    var busy: [String: String] = [:]
    var activity: [ActivityEntry] = []
    var alert: String?

    var verbosity = Verbosity(rawValue: UserDefaults.standard.string(forKey: "verbosity") ?? "") ?? .normal {
        didSet { UserDefaults.standard.set(verbosity.rawValue, forKey: "verbosity") }
    }

    private var pollTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?

    var selectedMachine: Machine? { machines.first { $0.name == selectedMachineName } }

    /// The selected machine, if its Docker engine is reachable.
    var dockerMachine: Machine? {
        guard let machine = selectedMachine, machine.isRunning, machine.usesDocker else { return nil }
        return machine
    }

    var runningCount: Int { machines.filter(\.isRunning).count }

    // MARK: - Polling

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshMachines()
                await self?.refreshContainers()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStats()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func refreshMachines() async {
        let result = await Shell.run("colima", ["list", "--json"])
        colimaMissing = result.status == 127
        dockerMissing = Shell.locate("docker") == nil
        machinesLoaded = true
        guard result.ok else { return }

        let list = decodeLines(Machine.self, from: result.stdout)
        if list != machines { machines = list }

        if selectedMachineName == nil || !list.contains(where: { $0.name == selectedMachineName }) {
            selectedMachineName = (list.first { $0.isRunning } ?? list.first)?.name
        }
    }

    func refreshContainers() async {
        guard dockerMachine != nil else {
            containers = []
            stats = [:]
            return
        }
        let result = await docker(["ps", "-a", "--format", "{{json .}}"])
        guard result.ok else {
            dockerError = result.message
            return
        }
        dockerError = nil
        let list = decodeLines(Container.self, from: result.stdout)
            .sorted { ($0.composeProject ?? "~", $0.name) < ($1.composeProject ?? "~", $1.name) }
        if list != containers { containers = list }
    }

    func refreshStats() async {
        guard dockerMachine != nil, containers.contains(where: \.isRunning) else {
            if !stats.isEmpty { stats = [:] }
            return
        }
        let result = await docker(["stats", "--no-stream", "--format", "{{json .}}"])
        guard result.ok else { return }
        stats = Dictionary(
            decodeLines(ContainerStats.self, from: result.stdout).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func refreshImages() async {
        guard dockerMachine != nil else { images = []; return }
        let result = await docker(["images", "--format", "{{json .}}"])
        if result.ok { images = decodeLines(DockerImage.self, from: result.stdout) }
    }

    func refreshVolumes() async {
        guard dockerMachine != nil else { volumes = []; return }
        let result = await docker(["volume", "ls", "--format", "{{json .}}"])
        if result.ok { volumes = decodeLines(DockerVolume.self, from: result.stdout) }
    }

    func selectMachine(_ name: String) {
        guard name != selectedMachineName else { return }
        selectedMachineName = name
        containers = []
        stats = [:]
        images = []
        volumes = []
        Task {
            await refreshContainers()
            await refreshImages()
            await refreshVolumes()
        }
    }

    // MARK: - Machine actions

    func start(_ machine: Machine) {
        track("Start \(machine.name)", busyKey: machine.name, busyLabel: "Starting…",
              tool: "colima", args: ["start", machine.name])
    }

    func stop(_ machine: Machine, force: Bool = false) {
        track("Stop \(machine.name)", busyKey: machine.name, busyLabel: "Stopping…",
              tool: "colima", args: ["stop", machine.name] + (force ? ["--force"] : []))
    }

    func restart(_ machine: Machine, force: Bool = false) {
        track("Restart \(machine.name)", busyKey: machine.name, busyLabel: "Restarting…",
              tool: "colima", args: ["restart", machine.name] + (force ? ["--force"] : []))
    }

    func delete(_ machine: Machine, includeData: Bool) {
        track("Delete \(machine.name)", busyKey: machine.name, busyLabel: "Deleting…",
              tool: "colima", args: ["delete", machine.name, "--force"] + (includeData ? ["--data"] : []))
    }

    func create(_ config: MachineConfig) {
        track("Create \(config.name)", busyKey: config.name, busyLabel: "Creating…",
              tool: "colima", args: config.createArguments(template: templateSettings()))
    }

    /// Colima's template for new machines. It doesn't exist until someone creates it.
    static var templateFile: URL { Machine.colimaHome.appendingPathComponent("_templates/default.yaml") }

    /// The settings new machines start from: Colima's template, if there is one.
    func templateSettings() -> MachineConfig? {
        guard let text = try? String(contentsOf: Self.templateFile, encoding: .utf8) else { return nil }
        return MachineConfig(name: "", yaml: text)
    }

    /// Reads a machine's current settings from its `colima.yaml`.
    func settings(for machine: Machine) -> MachineConfig {
        let text = (try? String(contentsOf: machine.configFile, encoding: .utf8)) ?? ""
        return MachineConfig(name: machine.name, yaml: text)
    }

    /// Saves changed settings into the machine's `colima.yaml`. Colima reads them the next time
    /// the machine starts, so `andApply` restarts (or starts) it right away.
    func saveSettings(_ config: MachineConfig, for machine: Machine, original: MachineConfig, andApply: Bool) {
        do {
            let text = try String(contentsOf: machine.configFile, encoding: .utf8)
            try config.applied(to: text, changedFrom: original)
                .write(to: machine.configFile, atomically: true, encoding: .utf8)
        } catch {
            alert = "Couldn't save the settings for \(machine.name).\n\n\(error.localizedDescription)"
            return
        }
        logActivity("Saved settings for \(machine.name)", detail: machine.configFile.path)
        guard andApply else { return }
        if machine.isRunning { restart(machine) } else { start(machine) }
    }

    /// Saves the template new machines start from, creating it if needed.
    func saveTemplate(_ config: MachineConfig, original: MachineConfig?) {
        let url = Self.templateFile
        do {
            let existing = try? String(contentsOf: url, encoding: .utf8)
            // A new file gets every value, so it doesn't depend on Colima's own starter template.
            let text = config.applied(to: existing ?? "", changedFrom: existing == nil ? nil : original)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alert = "Couldn't save the template.\n\n\(error.localizedDescription)"
            return
        }
        logActivity("Saved template for new machines", detail: url.path)
    }

    func kubernetes(_ machine: Machine, _ verb: String) {
        let labels = ["start": "Starting Kubernetes…", "stop": "Stopping Kubernetes…",
                      "reset": "Resetting Kubernetes…", "delete": "Deleting Kubernetes…"]
        track("Kubernetes \(verb) on \(machine.name)", busyKey: machine.name, busyLabel: labels[verb] ?? "Working…",
              tool: "colima", args: ["kubernetes", verb, "--profile", machine.name])
    }

    func updateRuntime(_ machine: Machine) {
        track("Update runtime on \(machine.name)", busyKey: machine.name, busyLabel: "Updating…",
              tool: "colima", args: ["update", machine.name])
    }

    /// `colima status --extended` as label/value pairs. Empty when the machine isn't running.
    func status(of machine: Machine) async -> [(key: String, value: String)] {
        let result = await Shell.run("colima", ["status", machine.name, "--extended", "--json"])
        guard result.ok,
              let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object
            .compactMap { key, value -> (String, String)? in
                let text: String
                switch value {
                case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
                    text = number.boolValue ? "Yes" : "No"
                case let number as NSNumber where ["memory", "disk"].contains(key) && number.int64Value > 0:
                    text = number.int64Value.gib
                case let array as [Any]:
                    text = array.map { "\($0)" }.joined(separator: ", ")
                case is NSNull:
                    return nil
                default:
                    text = "\(value)"
                }
                return text.isEmpty ? nil : (Self.statusLabel(key), text)
            }
            .sorted { $0.0 < $1.0 }
    }

    /// "ip_address" → "IP address", "docker_socket" → "Docker socket".
    private static func statusLabel(_ key: String) -> String {
        let words = key.replacingOccurrences(of: "_", with: " ")
        let acronyms = ["ip": "IP", "dns": "DNS", "cpu": "CPU", "vm": "VM", "ssh": "SSH"]
        let fixed = words.split(separator: " ").map { acronyms[String($0)] ?? String($0) }.joined(separator: " ")
        return fixed.prefix(1).uppercased() + fixed.dropFirst()
    }

    func version(of machine: Machine? = nil) async -> String {
        let result = await Shell.run("colima", ["version"] + (machine.map { [$0.name] } ?? []))
        return result.ok ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : result.message
    }

    func sshConfig(for machine: Machine) async -> String {
        let result = await Shell.run("colima", ["ssh-config", machine.name])
        return result.ok ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : result.message
    }

    /// Runs a shell command inside the machine (`colima ssh -- sh -c ...`).
    func run(_ command: String, in machine: Machine) async -> CommandResult {
        await Shell.run("colima", ["ssh", "--profile", machine.name, "--", "sh", "-c", command])
    }

    func installNerdctl(for machine: Machine, path: String, force: Bool) {
        track("Install nerdctl command", busyKey: "nerdctl", busyLabel: "Installing…",
              tool: "colima", args: ["nerdctl", "install", "--profile", machine.name, "--path", path] + (force ? ["--force"] : []))
    }

    func openNerdctl(_ machine: Machine) {
        runInTerminal("colima nerdctl --profile \(shellQuote(machine.name)) -- ps -a")
    }

    // MARK: - AI models

    func setUpModels(_ machine: Machine) {
        track("Set up AI models on \(machine.name)", busyKey: "model:\(machine.name)", busyLabel: "Setting up…",
              tool: "colima", args: ["model", "setup", "--profile", machine.name])
    }

    func listModels(_ machine: Machine) async -> CommandResult {
        await Shell.run("colima", ["model", "--profile", machine.name, "list"])
    }

    func pullModel(_ model: String, on machine: Machine) {
        track("Pull model \(model)", busyKey: "model:\(machine.name)", busyLabel: "Pulling…",
              tool: "colima", args: ["model", "--profile", machine.name, "pull", model])
    }

    /// `run` is an interactive chat and `serve` runs until stopped, so both open in Terminal.
    func openModel(_ model: String, on machine: Machine, verb: String) {
        runInTerminal("colima model --profile \(shellQuote(machine.name)) \(verb) \(shellQuote(model))")
    }

    // MARK: - Colima-wide tools

    func prune(includeLima: Bool) {
        track("Clean up downloaded files", busyKey: "prune", busyLabel: "Cleaning…",
              tool: "colima", args: ["prune", "--force"] + (includeLima ? ["--all"] : []))
    }

    /// The settings a new template starts from: the first machine's, or the app's defaults.
    /// (Colima's own starter template, from `colima template`, defaults to QEMU rather than vz,
    /// which would quietly change what new machines get.)
    func newTemplateSettings() -> MachineConfig {
        var config = machines.first.map { settings(for: $0) } ?? MachineConfig()
        config.name = ""
        return config
    }

    // MARK: - Setup

    var brewMissing: Bool { Shell.locate("brew") == nil }

    /// Installs whatever's missing of Colima and the Docker CLI with Homebrew.
    func installTools() {
        let packages = (colimaMissing ? ["colima"] : []) + (dockerMissing ? ["docker"] : [])
        guard !packages.isEmpty else { return }
        track("Install \(packages.joined(separator: " and "))", busyKey: "install", busyLabel: "Installing…",
              steps: [["brew", "install"] + packages], env: ["NONINTERACTIVE": "1", "HOMEBREW_NO_ENV_HINTS": "1"])
    }

    /// Homebrew's installer asks for your password, so it runs in Terminal.
    func installHomebrew() {
        runInTerminal(#"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#)
    }

    func openShell(_ machine: Machine) {
        runInTerminal("colima ssh -p \(shellQuote(machine.name))")
    }

    // MARK: - Docker actions

    func containerAction(_ container: Container, _ verb: String) {
        let labels = ["start": "Starting…", "stop": "Stopping…", "restart": "Restarting…",
                      "pause": "Pausing…", "unpause": "Resuming…"]
        track("\(verb.capitalized) \(container.name)", busyKey: container.id,
              busyLabel: labels[verb] ?? "Working…", tool: "docker", args: [verb, container.id], docker: true)
    }

    func remove(_ container: Container) {
        track("Remove \(container.name)", busyKey: container.id, busyLabel: "Removing…",
              tool: "docker", args: ["rm", "-f", container.id], docker: true)
    }

    func composeAction(project: String, _ verb: String) {
        let ids = containers.filter { $0.composeProject == project }.map(\.id)
        guard !ids.isEmpty else { return }
        track("\(verb.capitalized) \(project)", busyKey: "project:\(project)", busyLabel: "Working…",
              tool: "docker", args: [verb] + ids, docker: true)
    }

    func openShell(_ container: Container) {
        guard let machine = dockerMachine else { return }
        runInTerminal("DOCKER_HOST=\(shellQuote("unix://" + machine.dockerSocket)) docker exec -it \(container.id) sh -c 'command -v bash >/dev/null && exec bash || exec sh'")
    }

    func logs(for container: Container, tail: Int = 500) async -> String {
        guard let machine = dockerMachine else { return "" }
        // Go through sh so stdout and stderr stay interleaved in order.
        let result = await Shell.run(
            "sh", ["-c", "exec docker logs --tail \"$1\" \"$0\" 2>&1", container.id, "\(tail)"],
            env: dockerEnvironment(machine)
        )
        return result.stdout
    }

    func pull(_ reference: String) {
        track("Pull \(reference)", busyKey: "pull", busyLabel: "Pulling…",
              tool: "docker", args: ["pull", reference], docker: true)
    }

    func remove(_ image: DockerImage) {
        track("Remove \(image.reference)", busyKey: image.id, busyLabel: "Removing…",
              tool: "docker", args: ["rmi", image.reference], docker: true)
    }

    func pruneImages() {
        track("Remove unused images", busyKey: "prune-images", busyLabel: "Cleaning…",
              tool: "docker", args: ["image", "prune", "-a", "-f"], docker: true)
    }

    func remove(_ volume: DockerVolume) {
        track("Remove volume \(volume.name)", busyKey: volume.name, busyLabel: "Removing…",
              tool: "docker", args: ["volume", "rm", volume.name], docker: true)
    }

    func pruneVolumes() {
        track("Remove unused volumes", busyKey: "prune-volumes", busyLabel: "Cleaning…",
              tool: "docker", args: ["volume", "prune", "-a", "-f"], docker: true)
    }

    /// Records something the app did itself, without running a command.
    private func logActivity(_ title: String, detail: String) {
        var entry = ActivityEntry(title: title, command: detail)
        entry.state = .succeeded
        activity.insert(entry, at: 0)
    }

    func clearActivity() {
        activity.removeAll { $0.state != .running }
    }

    // MARK: - Plumbing

    private func dockerEnvironment(_ machine: Machine) -> [String: String] {
        ["DOCKER_HOST": "unix://" + machine.dockerSocket, "DOCKER_CONTEXT": ""]
    }

    private func docker(_ args: [String]) async -> CommandResult {
        guard let machine = dockerMachine else {
            return CommandResult(status: 1, stdout: "", stderr: "No running Docker machine selected.")
        }
        return await Shell.run("docker", args, env: dockerEnvironment(machine))
    }

    /// Runs a command as a visible activity: marks it busy, streams output into the activity log,
    /// shows an alert if it fails, and refreshes everything afterwards.
    private func track(_ title: String, busyKey: String, busyLabel: String,
                       tool: String, args: [String], docker: Bool = false) {
        var env: [String: String] = [:]
        if docker {
            guard let machine = dockerMachine else { return }
            env = dockerEnvironment(machine)
        }
        track(title, busyKey: busyKey, busyLabel: busyLabel, steps: [[tool] + args], env: env)
    }

    /// Runs several commands in order, stopping at the first failure.
    private func track(_ title: String, busyKey: String, busyLabel: String,
                       steps: [[String]], env: [String: String] = [:]) {
        // Colima's log detail setting applies to actions, not to the quiet background refreshes.
        // `colima model` passes its arguments through to the model runner, so leave it alone.
        let steps = steps.map { $0.first == "colima" && $0.dropFirst().first != "model" ? $0 + verbosity.flags : $0 }
        let entry = ActivityEntry(title: title, command: steps.map { $0.joined(separator: " ") }.joined(separator: " && "))
        let entryID = entry.id
        activity.insert(entry, at: 0)
        if activity.count > 100 { activity.removeLast(activity.count - 100) }
        busy[busyKey] = busyLabel

        Task {
            var result = CommandResult(status: 0, stdout: "", stderr: "")
            for step in steps {
                result = await Shell.run(step[0], Array(step.dropFirst()), env: env) { chunk in
                    Task { @MainActor [weak self] in self?.appendOutput(chunk, to: entryID) }
                }
                if !result.ok { break }
            }
            busy[busyKey] = nil
            if let index = activity.firstIndex(where: { $0.id == entryID }) {
                activity[index].state = result.ok ? .succeeded : .failed
            }
            if !result.ok {
                alert = "\(title) failed.\n\n\(result.message.suffix(800))"
            }
            await refreshMachines()
            await refreshContainers()
            await refreshImages()
            await refreshVolumes()
        }
    }

    private func appendOutput(_ chunk: String, to id: UUID) {
        guard let index = activity.firstIndex(where: { $0.id == id }) else { return }
        activity[index].output += chunk
    }

    private func runInTerminal(_ command: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
        Task { _ = await Shell.run("osascript", ["-e", script]) }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
