import SwiftUI

struct ActivityView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if store.activity.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "list.bullet.rectangle",
                                       description: Text("Starting, stopping and other actions show their output here."))
            } else {
                List(store.activity) { entry in
                    ActivityRow(entry: entry)
                }
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem {
                Button("Clear", action: store.clearActivity)
                    .disabled(!store.activity.contains { $0.state != .running })
            }
        }
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(entry.output.isEmpty ? "No output." : entry.output)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(entry.output.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        } label: {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.body.weight(.medium))
                    Text(entry.command)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(entry.started, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { expanded = entry.state == .failed }
    }

    @ViewBuilder private var icon: some View {
        switch entry.state {
        case .running: ProgressView().controlSize(.small).frame(width: 16)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}
