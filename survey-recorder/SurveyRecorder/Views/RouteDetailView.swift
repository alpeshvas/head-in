import SwiftUI

/// One route: its checkpoints, a button to add a pass (pre-filled), and the list
/// of recorded passes for it.
struct RouteDetailView: View {
    let route: RouteRecord
    @Environment(RouteRegistry.self) private var registry

    @State private var showNewPass = false
    @State private var showCheckpointEditor = false
    @State private var passes: [PassFile] = []

    /// Live record from the registry (an ad-hoc pass started here may have just
    /// filled in checkpoints); falls back to the value we were handed.
    private var current: RouteRecord {
        registry.record(venueId: route.venueId, routeId: route.routeId) ?? route
    }

    var body: some View {
        List {
            checkpointsSection
            startPassSection
            passesSection
        }
        .navigationTitle(route.routeId)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .refreshable { reload() }
        .sheet(isPresented: $showNewPass, onDismiss: reload) {
            NavigationStack {
                SetupView(route: current)
            }
        }
        .sheet(isPresented: $showCheckpointEditor) {
            NavigationStack {
                CheckpointEditorView(route: current)
            }
        }
    }

    private var checkpointsSection: some View {
        Section {
            if current.checkpoints.isEmpty {
                Text("No checkpoints recorded yet — the first pass can name them while you walk (ad-hoc).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(current.checkpoints.enumerated()), id: \.offset) { index, name in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(.quaternary, in: Circle())
                        Text(name)
                    }
                }
            }
        } header: {
            HStack {
                Text(current.venueId)
                Spacer()
                Button("Edit") { showCheckpointEditor = true }
                    .font(.caption.weight(.semibold))
                    .textCase(nil)
            }
        } footer: {
            Text("Default carry: \(current.pose.rawValue.capitalized) · \(current.direction.rawValue.capitalized)")
        }
    }

    private var startPassSection: some View {
        Section {
            Button {
                showNewPass = true
            } label: {
                Label("Start new pass", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
                    .font(.headline)
            }
        }
        .listRowBackground(Color.accentColor)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var passesSection: some View {
        Section {
            if passes.isEmpty {
                Text("No recordings on this phone. (Passes you offloaded and deleted aren't shown, but the route is kept.)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(passes) { pass in
                    PassRow(pass: pass)
                }
                .onDelete(perform: deletePasses)
            }
        } header: {
            Text(passes.isEmpty ? "Passes" : "\(passes.count) passes on device")
        }
    }

    private func reload() {
        passes = registry.passes(for: route)
    }

    private func deletePasses(at offsets: IndexSet) {
        for index in offsets {
            try? FileManager.default.removeItem(at: passes[index].url)
        }
        reload()
    }
}

private struct PassRow: View {
    let pass: PassFile

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(pass.passLabel)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(pass.isNegative ? .orange : .primary)
                    if pass.hasGroundTruth {
                        Label("GT", systemImage: "scope")
                            .font(.caption2.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.green)
                    }
                }
                Text("\(pass.direction.capitalized) · \(pass.pose.capitalized) · \(pass.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ShareLink(item: pass.url) {
                Image(systemName: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
        }
        .padding(.vertical, 2)
    }
}
