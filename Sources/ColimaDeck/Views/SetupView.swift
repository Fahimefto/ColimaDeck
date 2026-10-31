import SwiftUI

/// Shown when Colima or the Docker CLI isn't installed. Installs them with Homebrew.
struct SetupView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var brewMissing = Shell.locate("brew") == nil

    private var installing: Bool { store.busy["install"] != nil }
    private var allSet: Bool { !store.colimaMissing && !store.dockerMissing }
    private var installEntry: ActivityEntry? { store.activity.first { $0.title.hasPrefix("Install ") } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(allSet ? "You're all set" : "Let's get you set up")
                        .font(.title2.weight(.semibold))
                    Text(allSet
                         ? "Colima and Docker are installed. Create your first machine to get started."
                         : "ColimaDeck needs a couple of free tools to run containers on your Mac.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                requirement("Homebrew", detail: "Installs the other tools", installed: !brewMissing)
                requirement("Colima", detail: "Runs a small Linux VM for your containers", installed: !store.colimaMissing)
                requirement("Docker CLI", detail: "The `docker` command", installed: !store.dockerMissing)
            }

            if let entry = installEntry, installing || entry.state == .failed {
                OutputText(text: entry.output, failed: entry.state == .failed)
                    .frame(height: 160)
            }

            HStack {
                if installing {
                    ProgressView().controlSize(.small)
                    Text("Installing… this can take a few minutes.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if allSet {
                    Button("Get Started") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else if brewMissing {
                    Button("Not Now") { dismiss() }
                    Button("Check Again") {
                        brewMissing = Shell.locate("brew") == nil
                        Task { await store.refreshMachines() }
                    }
                    Button("Install Homebrew in Terminal") { store.installHomebrew() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now") { dismiss() }
                        .disabled(installing)
                    Button("Install") { store.installTools() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(installing)
                }
            }

            if brewMissing && !allSet {
                Text("Homebrew's installer asks for your Mac password, so it runs in Terminal. When it finishes, come back and click Check Again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func requirement(_ name: String, detail: String, installed: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: installed ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(installed ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(installed ? "Installed" : "Not installed")
                .font(.caption)
                .foregroundStyle(installed ? .green : .secondary)
        }
    }
}
