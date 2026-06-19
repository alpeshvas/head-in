import SwiftUI

/// Rename / add / remove a route's checkpoints. Edits the durable route
/// definition (the registry), which drives the predefined tap-through and the
/// names later passes record. Already-recorded `.jsonl` passes keep their
/// original anchor names — this does not rewrite history.
struct CheckpointEditorView: View {
    let route: RouteRecord
    @Environment(RouteRegistry.self) private var registry
    @Environment(\.dismiss) private var dismiss

    @State private var items: [Item]

    private struct Item: Identifiable {
        let id = UUID()
        var name: String
    }

    init(route: RouteRecord) {
        self.route = route
        _items = State(initialValue: route.checkpoints.map { Item(name: $0) })
    }

    private var cleaned: [String] {
        items.map { $0.name.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var canSave: Bool { cleaned.count >= 2 }

    var body: some View {
        Form {
            Section {
                ForEach($items) { $item in
                    HStack(spacing: 12) {
                        Image(systemName: "\(indexOf(item) + 1).circle.fill")
                            .foregroundStyle(.secondary)
                        TextField("Checkpoint name", text: $item.name)
                            .autocorrectionDisabled()
                    }
                }
                .onDelete { items.remove(atOffsets: $0) }
                .onMove { items.move(fromOffsets: $0, toOffset: $1) }

                Button {
                    items.append(Item(name: ""))
                } label: {
                    Label("Add checkpoint", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Checkpoints (in walking order)")
            } footer: {
                if canSave {
                    Text("Renaming affects this list and future passes. Already-recorded passes keep their original anchor names.")
                } else {
                    Text("A route needs at least 2 checkpoints. Blank rows are dropped on save.")
                }
            }
        }
        .navigationTitle("Edit Checkpoints")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(!canSave)
            }
            ToolbarItem(placement: .topBarLeading) { EditButton() }
        }
    }

    private func indexOf(_ item: Item) -> Int {
        items.firstIndex { $0.id == item.id } ?? 0
    }

    private func save() {
        registry.setCheckpoints(cleaned, venueId: route.venueId, routeId: route.routeId)
        dismiss()
    }
}
