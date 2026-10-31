import SwiftUI

struct VolumesView: View {
    @Environment(AppStore.self) private var store
    @State private var selection = Set<DockerVolume.ID>()
    @State private var search = ""
    @State private var confirmingPrune = false
    @State private var confirmingRemove = false

    private var filtered: [DockerVolume] {
        search.isEmpty ? store.volumes : store.volumes.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        DockerGate {
            Table(filtered, selection: $selection) {
                TableColumn("Name") { Text($0.name).lineLimit(1).truncationMode(.middle) }
                TableColumn("Driver") { Text($0.driver).foregroundStyle(.secondary) }
                    .width(min: 60, ideal: 80)
                TableColumn("Location in VM") {
                    Text($0.mountpoint).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .contextMenu(forSelectionType: DockerVolume.ID.self) { ids in
                Button("Remove", role: .destructive) {
                    selection = ids
                    confirmingRemove = true
                }
            }
            .overlay {
                if store.volumes.isEmpty {
                    ContentUnavailableView("No volumes", systemImage: "externaldrive",
                                           description: Text("Volumes keep container data between runs."))
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .task { await store.refreshVolumes() }
        }
        .navigationTitle("Volumes")
        .navigationSubtitle(store.volumes.isEmpty ? "" : "\(store.volumes.count) volumes")
        .searchable(text: $search, placement: .toolbar, prompt: "Filter volumes")
        .toolbar {
            ToolbarItemGroup {
                MachinePicker()
                Button {
                    confirmingRemove = true
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
                .help("Remove selected volumes")
                Button {
                    confirmingPrune = true
                } label: {
                    Label("Clean Up", systemImage: "sparkles")
                }
                .help("Remove volumes no container uses")
                .disabled(store.dockerMachine == nil)
            }
        }
        .confirmationDialog("Remove \(selection.count == 1 ? "this volume" : "\(selection.count) volumes")?",
                            isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) {
                for volume in store.volumes where selection.contains(volume.id) { store.remove(volume) }
                selection.removeAll()
            }
        } message: {
            Text("The data in it is deleted for good.")
        }
        .confirmationDialog("Remove all unused volumes?", isPresented: $confirmingPrune) {
            Button("Remove Unused Volumes", role: .destructive) { store.pruneVolumes() }
        } message: {
            Text("Volumes not used by any container are deleted, along with their data.")
        }
    }
}
