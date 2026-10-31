import AppKit
import Observation

enum SidebarItem: String, CaseIterable, Identifiable {
    case machines, containers, images, volumes, activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .machines: "Machines"
        case .containers: "Containers"
        case .images: "Images"
        case .volumes: "Volumes"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .machines: "desktopcomputer"
        case .containers: "shippingbox"
        case .images: "square.stack.3d.up"
        case .volumes: "externaldrive"
        case .activity: "list.bullet.rectangle"
        }
    }
}

@MainActor
@Observable
final class AppStore {
    var machines: [Machine] = []
    var machinesLoaded = false
    var colimaMissing = false

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

    func restart(_ machine: Machine) {
        track("Restart \(machine.name)", busyKey: machine.name, busyLabel: "Restarting…",
              tool: "colima", args: ["restart", machine.name])
    }

    func delete(_ machine: Machine, includeData: Bool) {
        track("Delete \(machine.name)", busyKey: machine.name, busyLabel: "Deleting…",
              tool: "colima", args: ["delete", machine.name, "--force"] + (includeData ? ["--data"] : []))
    }

    func create(_ config: MachineConfig) {
        track("Create \(config.name)", busyKey: config.name, busyLabel: "Creating…",
              tool: "colima", args: config.startArguments)
    }

    func openShell(_ machine: Machine) {
        runInTerminal("colima ssh -p \(shellQuote(machine.name))")
    }

    func openConfig(_ machine: Machine) {
        NSWorkspace.shared.open(machine.configFile)
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

        let entry = ActivityEntry(title: title, command: ([tool] + args).joined(separator: " "))
        let entryID = entry.id
        activity.insert(entry, at: 0)
        if activity.count > 100 { activity.removeLast(activity.count - 100) }
        busy[busyKey] = busyLabel

        Task {
            let result = await Shell.run(tool, args, env: env) { chunk in
                Task { @MainActor [weak self] in self?.appendOutput(chunk, to: entryID) }
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
