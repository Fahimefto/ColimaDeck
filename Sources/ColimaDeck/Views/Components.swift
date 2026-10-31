import SwiftUI

struct StatusDot: View {
    var color: Color
    var pulsing = false

    init(color: Color, pulsing: Bool = false) {
        self.color = color
        self.pulsing = pulsing
    }

    init(machine: Machine, busy: Bool) {
        self.init(color: busy ? .orange : (machine.isRunning ? .green : .secondary), pulsing: busy)
    }

    init(container: Container, busy: Bool) {
        let color: Color = busy ? .orange
            : container.isRunning ? .green
            : container.isPaused ? .yellow
            : .secondary
        self.init(color: color, pulsing: busy)
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(pulsing ? 0.5 : 1)
            .animation(pulsing ? .easeInOut(duration: 0.7).repeatForever() : .default, value: pulsing)
            .accessibilityHidden(true)
    }
}

/// A small horizontal bar for CPU and memory usage.
struct Meter: View {
    var label: String
    var value: Double // 0...100
    var text: String
    var tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint)
                        .frame(width: max(2, proxy.size.width * min(value, 100) / 100))
                }
            }
            .frame(width: 54, height: 5)
            Text(text)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(text)")
    }
}

struct Pill: View {
    var text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// Picks which machine's Docker engine the Docker views use.
struct MachinePicker: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.machines.count > 1 {
            Picker("Machine", selection: Binding(
                get: { store.selectedMachineName ?? "" },
                set: { store.selectMachine($0) }
            )) {
                ForEach(store.machines) { machine in
                    Text("\(machine.name)\(machine.isRunning ? "" : " (stopped)")").tag(machine.name)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Which machine's Docker engine to show")
        }
    }
}

/// Shows the content only when the selected machine has a reachable Docker engine,
/// otherwise explains why not and offers the fix.
struct DockerGate<Content: View>: View {
    @Environment(AppStore.self) private var store
    @ViewBuilder var content: () -> Content

    var body: some View {
        if store.dockerMachine != nil {
            content()
        } else if !store.machinesLoaded {
            ProgressView()
        } else if let machine = store.selectedMachine {
            if let label = store.busy[machine.name] {
                ContentUnavailableView {
                    Label(label, systemImage: "hourglass")
                } description: {
                    Text("\(machine.name) will be ready in a moment.")
                }
            } else if !machine.isRunning {
                ContentUnavailableView {
                    Label("\(machine.name) is stopped", systemImage: "moon.zzz")
                } description: {
                    Text("Start the machine to see its containers, images and volumes.")
                } actions: {
                    Button("Start \(machine.name)") { store.start(machine) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView(
                    "Docker isn't available",
                    systemImage: "shippingbox",
                    description: Text("\(machine.name) uses the \(machine.runtime) runtime. These views need a machine running the Docker runtime.")
                )
            }
        } else {
            ContentUnavailableView(
                "No machines yet",
                systemImage: "desktopcomputer",
                description: Text("Create a machine in Machines to get started.")
            )
        }
    }
}
