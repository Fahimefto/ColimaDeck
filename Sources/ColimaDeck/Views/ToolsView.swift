import SwiftUI

/// Colima-wide settings and maintenance that don't belong to one machine.
struct ToolsView: View {
    @Environment(AppStore.self) private var store
    @State private var version = ""
    @State private var includeLima = false
    @State private var confirmingPrune = false
    @State private var shell = "zsh"
    @State private var templateExists = FileManager.default.fileExists(atPath: AppStore.templateFile.path)
    @State private var editingTemplate: MachineConfig?

    private var completion: (file: String, line: String) {
        switch shell {
        case "bash": ("~/.bash_profile", "source <(colima completion bash)")
        case "fish": ("~/.config/fish/config.fish", "colima completion fish | source")
        default: ("~/.zshrc", "source <(colima completion zsh)")
        }
    }

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Colima") {
                LabeledContent("Version") {
                    Text(version.isEmpty ? "…" : version)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Location", value: Shell.locate("colima") ?? "Not found")
            }

            Section {
                LabeledContent("Template") {
                    Button(templateExists ? "Edit Template…" : "Create Template…") {
                        editingTemplate = store.templateSettings() ?? store.newTemplateSettings()
                    }
                }
            } header: {
                Text("Defaults for new machines")
            } footer: {
                Text(templateExists
                     ? "New machines start with these settings unless you turn that off when creating them."
                     : "There's no template yet, so new machines start with Colima's standard settings."
                        + (store.machines.isEmpty ? "" : " A new template starts from \(store.machines[0].name)'s settings."))
            }

            Section {
                Toggle("Also remove Lima's downloaded files", isOn: $includeLima)
                LabeledContent("Downloaded VM images") {
                    HStack {
                        if store.busy["prune"] != nil { ProgressView().controlSize(.small) }
                        Button("Clean Up…") { confirmingPrune = true }
                            .disabled(store.busy["prune"] != nil)
                    }
                }
            } header: {
                Text("Disk space")
            } footer: {
                Text("Colima keeps the images it downloads to create machines. Removing them frees space, and they download again next time you create a machine.")
            }

            Section {
                Picker("Detail in Activity", selection: $store.verbosity) {
                    ForEach(Verbosity.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Command output")
            } footer: {
                Text("More detail helps when a machine won't start.")
            }

            Section {
                Picker("Shell", selection: $shell) {
                    Text("zsh").tag("zsh")
                    Text("bash").tag("bash")
                    Text("fish").tag("fish")
                }
                LabeledContent("Add to \(completion.file)") {
                    HStack {
                        Text(completion.line).font(.callout.monospaced()).textSelection(.enabled)
                        Button("Copy") { copy(completion.line) }
                    }
                }
            } header: {
                Text("Tab completion in Terminal")
            } footer: {
                Text("Lets you press Tab to complete colima commands and options.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Tools")
        .task { version = await store.version() }
        .sheet(item: Binding(
            get: { editingTemplate.map { TemplateItem(config: $0) } },
            set: { editingTemplate = $0?.config }
        ), onDismiss: {
            templateExists = FileManager.default.fileExists(atPath: AppStore.templateFile.path)
        }) { item in
            MachineSettingsSheet(mode: .template(exists: templateExists), original: item.config)
        }
        .confirmationDialog("Remove downloaded files?", isPresented: $confirmingPrune) {
            Button("Remove", role: .destructive) { store.prune(includeLima: includeLima) }
        } message: {
            Text("Your machines aren't affected.")
        }
    }
}

private struct TemplateItem: Identifiable {
    let config: MachineConfig
    var id: String { "template" } // stable, so the sheet isn't re-created on every redraw
}
