import SwiftUI

struct ImagesView: View {
    @Environment(AppStore.self) private var store
    @State private var selection = Set<DockerImage.ID>()
    @State private var search = ""
    @State private var pullReference = ""
    @State private var confirmingPrune = false
    @State private var pendingRemoval = Set<DockerImage.ID>()

    private var filtered: [DockerImage] {
        search.isEmpty ? store.images : store.images.filter { $0.reference.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        DockerGate {
            VStack(spacing: 0) {
                HStack {
                    TextField("Image to pull, like postgres:17", text: $pullReference)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(pull)
                    Button("Pull", action: pull)
                        .disabled(pullReference.trimmingCharacters(in: .whitespaces).isEmpty || store.busy["pull"] != nil)
                    if store.busy["pull"] != nil {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(12)
                Divider()

                Table(filtered, selection: $selection) {
                    TableColumn("Repository") { Text($0.repository).lineLimit(1) }
                    TableColumn("Tag") { Text($0.tag).foregroundStyle(.secondary) }
                        .width(min: 60, ideal: 100)
                    TableColumn("ID") { Text($0.id).font(.body.monospaced()).foregroundStyle(.secondary) }
                        .width(min: 90, ideal: 110)
                    TableColumn("Size") { Text($0.size).monospacedDigit() }
                        .width(min: 60, ideal: 80)
                    TableColumn("Created") { Text($0.createdSince).foregroundStyle(.secondary) }
                        .width(min: 80, ideal: 120)
                }
                .contextMenu(forSelectionType: DockerImage.ID.self) { ids in
                    Button("Remove", role: .destructive) { pendingRemoval = ids }
                }
                .overlay {
                    if store.images.isEmpty {
                        ContentUnavailableView("No images", systemImage: "square.stack.3d.up",
                                               description: Text("Pull one above to get started."))
                    } else if filtered.isEmpty {
                        ContentUnavailableView.search(text: search)
                    }
                }
            }
            .task { await store.refreshImages() }
        }
        .navigationTitle("Images")
        .navigationSubtitle(store.images.isEmpty ? "" : "\(store.images.count) images")
        .searchable(text: $search, placement: .toolbar, prompt: "Filter images")
        .toolbar {
            ToolbarItemGroup {
                MachinePicker()
                Button {
                    pendingRemoval = selection
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
                .help("Remove selected images")
                Button {
                    confirmingPrune = true
                } label: {
                    Label("Clean Up", systemImage: "sparkles")
                }
                .help("Remove images no container uses")
                .disabled(store.dockerMachine == nil)
            }
        }
        .confirmationDialog("Remove \(pendingRemoval.count == 1 ? "this image" : "\(pendingRemoval.count) images")?",
                            isPresented: Binding(get: { !pendingRemoval.isEmpty }, set: { if !$0 { pendingRemoval = [] } })) {
            Button("Remove", role: .destructive) {
                remove(pendingRemoval)
                pendingRemoval = []
            }
        } message: {
            Text("You can pull them again later.")
        }
        .confirmationDialog("Remove all unused images?", isPresented: $confirmingPrune) {
            Button("Remove Unused Images", role: .destructive) { store.pruneImages() }
        } message: {
            Text("Images not used by any container are deleted. You can pull them again later.")
        }
    }

    private func pull() {
        let reference = pullReference.trimmingCharacters(in: .whitespaces)
        guard !reference.isEmpty else { return }
        store.pull(reference)
        pullReference = ""
    }

    private func remove(_ ids: Set<DockerImage.ID>) {
        for image in store.images where ids.contains(image.id) { store.remove(image) }
        selection.subtract(ids)
    }
}
