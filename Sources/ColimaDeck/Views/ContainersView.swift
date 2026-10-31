import SwiftUI

struct ContainersView: View {
    @Environment(AppStore.self) private var store
    @State private var selectedID: Container.ID?
    @State private var search = ""
    @State private var runningOnly = false
    @State private var showingDetail = true

    private var filtered: [Container] {
        store.containers.filter { container in
            (!runningOnly || container.isRunning)
                && (search.isEmpty
                    || container.name.localizedCaseInsensitiveContains(search)
                    || container.image.localizedCaseInsensitiveContains(search)
                    || (container.composeProject?.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    /// Compose projects first (alphabetically), then standalone containers.
    private var groups: [(project: String?, containers: [Container])] {
        let byProject = Dictionary(grouping: filtered, by: \.composeProject)
        let projects = byProject.keys.compactMap { $0 }.sorted()
        var result = projects.map { (project: Optional($0), containers: byProject[$0] ?? []) }
        if let standalone = byProject[nil] { result.append((project: nil, containers: standalone)) }
        return result
    }

    private var selected: Container? { store.containers.first { $0.id == selectedID } }

    var body: some View {
        DockerGate {
            if store.containers.isEmpty {
                ContentUnavailableView {
                    Label("No containers", systemImage: "shippingbox")
                } description: {
                    if let error = store.dockerError {
                        Text(error)
                    } else {
                        Text("Run one from your terminal and it shows up here:")
                        Text("docker run -d -p 8080:80 nginx").font(.body.monospaced()).textSelection(.enabled)
                    }
                }
            } else {
                List(selection: $selectedID) {
                    ForEach(groups, id: \.project) { group in
                        Section {
                            ForEach(group.containers) { container in
                                ContainerRow(container: container, stats: store.stats[container.id])
                                    .tag(container.id)
                                    .contextMenu { ContainerMenu(container: container) }
                            }
                        } header: {
                            GroupHeader(project: group.project, containers: group.containers)
                        }
                    }
                }
                .overlay {
                    if filtered.isEmpty {
                        ContentUnavailableView.search(text: search)
                    }
                }
                .inspector(isPresented: $showingDetail) {
                    Group {
                        if let selected {
                            ContainerDetail(container: selected)
                        } else {
                            ContentUnavailableView("Select a container", systemImage: "sidebar.right",
                                                   description: Text("See its details and logs here."))
                        }
                    }
                    .inspectorColumnWidth(min: 320, ideal: 420, max: 700)
                }
            }
        }
        .navigationTitle("Containers")
        .navigationSubtitle(subtitle)
        .searchable(text: $search, placement: .toolbar, prompt: "Filter containers")
        .toolbar {
            ToolbarItemGroup {
                MachinePicker()
                Toggle(isOn: $runningOnly) {
                    Label("Running Only", systemImage: "play.circle")
                }
                .help("Show only running containers")
                Button {
                    showingDetail.toggle()
                } label: {
                    Label("Details", systemImage: "sidebar.right")
                }
                .help("Show or hide details")
            }
        }
    }

    private var subtitle: String {
        guard store.dockerMachine != nil, !store.containers.isEmpty else { return "" }
        return "\(store.containers.filter(\.isRunning).count) of \(store.containers.count) running"
    }
}

private struct GroupHeader: View {
    @Environment(AppStore.self) private var store
    let project: String?
    let containers: [Container]

    var body: some View {
        HStack {
            if let project {
                Label(project, systemImage: "square.3.layers.3d")
                Spacer()
                let anyRunning = containers.contains(where: \.isRunning)
                Button(anyRunning ? "Stop All" : "Start All") {
                    store.composeAction(project: project, anyRunning ? "stop" : "start")
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(store.busy["project:\(project)"] != nil)
            } else {
                Text("Containers")
            }
        }
    }
}

private struct ContainerRow: View {
    @Environment(AppStore.self) private var store
    let container: Container
    let stats: ContainerStats?

    private var busyLabel: String? { store.busy[container.id] }

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(container: container, busy: busyLabel != nil)

            VStack(alignment: .leading, spacing: 2) {
                Text(container.composeService ?? container.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(busyLabel ?? "\(container.image) · \(container.status)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            ForEach(container.publishedPorts.prefix(3), id: \.self) { port in
                Link(destination: URL(string: "http://localhost:\(port)")!) {
                    Pill(text: ":\(port)", tint: .accentColor)
                }
                .help("Open http://localhost:\(port)")
            }

            if container.isRunning, let stats {
                VStack(alignment: .leading, spacing: 3) {
                    Meter(label: "CPU", value: stats.cpuValue, text: stats.cpu, tint: .blue)
                    Meter(label: "MEM", value: stats.memValue, text: stats.memUsed, tint: .purple)
                }
            }

            HStack(spacing: 2) {
                if container.isRunning {
                    iconButton("stop.fill", "Stop") { store.containerAction(container, "stop") }
                    iconButton("arrow.clockwise", "Restart") { store.containerAction(container, "restart") }
                } else if container.isPaused {
                    iconButton("play.fill", "Resume") { store.containerAction(container, "unpause") }
                } else {
                    iconButton("play.fill", "Start") { store.containerAction(container, "start") }
                }
                iconButton("trash", "Remove") { store.remove(container) }
            }
            .disabled(busyLabel != nil)
        }
        .padding(.vertical, 4)
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel("\(label) \(container.name)")
    }
}

private struct ContainerMenu: View {
    @Environment(AppStore.self) private var store
    let container: Container

    var body: some View {
        if container.isRunning {
            Button("Open Terminal") { store.openShell(container) }
            Button("Stop") { store.containerAction(container, "stop") }
            Button("Restart") { store.containerAction(container, "restart") }
            Button("Pause") { store.containerAction(container, "pause") }
        } else if container.isPaused {
            Button("Resume") { store.containerAction(container, "unpause") }
        } else {
            Button("Start") { store.containerAction(container, "start") }
        }
        Divider()
        Button("Copy ID") { copy(container.id) }
        Button("Copy Name") { copy(container.name) }
        Divider()
        Button("Remove", role: .destructive) { store.remove(container) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct ContainerDetail: View {
    @Environment(AppStore.self) private var store
    let container: Container
    @State private var logs = ""
    @State private var follow = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    StatusDot(container: container, busy: store.busy[container.id] != nil)
                    Text(container.name).font(.title3.weight(.semibold)).lineLimit(1)
                    Spacer()
                    if container.isRunning {
                        Button("Terminal") { store.openShell(container) }
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    info("Image", container.image)
                    info("Status", container.status)
                    info("ID", container.id)
                    if !container.ports.isEmpty { info("Ports", container.ports) }
                    if let project = container.composeProject { info("Project", project) }
                    info("Created", container.createdAt)
                }
                .font(.callout)
            }
            .padding(16)

            Divider()

            HStack {
                Text("Logs").font(.headline)
                Spacer()
                Toggle("Follow", isOn: $follow)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Button {
                    Task { logs = await store.logs(for: container) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload logs")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(logs.isEmpty ? "No output yet." : logs)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(logs.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: logs) {
                    if follow { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .onChange(of: container.id) { logs = "" }
        // Restarts when the container changes or Follow is switched back on.
        .task(id: "\(container.id)|\(follow)") {
            while !Task.isCancelled {
                let latest = await store.logs(for: container)
                if latest != logs { logs = latest }
                guard follow else { break }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
