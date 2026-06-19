import SwiftUI

/// Survey-tab root. Browse venues → routes (the durable registry), open a route
/// to add a pass, or create a brand-new route.
struct RouteLibraryView: View {
    @Environment(RouteRegistry.self) private var registry
    @State private var showNewRoute = false
    @State private var passCounts: [RouteRecord.ID: Int] = [:]

    var body: some View {
        List {
            if registry.venues.isEmpty {
                ContentUnavailableView {
                    Label("No routes yet", systemImage: "map")
                } description: {
                    Text("Tap + to survey your first route. Each route remembers its checkpoints, so later passes are a quick tap-through.")
                }
            }
            ForEach(registry.venues, id: \.venue) { group in
                Section(group.venue) {
                    ForEach(group.routes) { route in
                        NavigationLink(value: route) {
                            RouteRow(route: route, passCount: passCounts[route.id] ?? 0)
                        }
                    }
                }
            }
        }
        .navigationTitle("Routes")
        .onAppear { passCounts = registry.passCounts() }
        .navigationDestination(for: RouteRecord.self) { route in
            RouteDetailView(route: route)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNewRoute = true
                } label: {
                    Label("New route", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showNewRoute, onDismiss: { passCounts = registry.passCounts() }) {
            NavigationStack {
                SetupView(route: nil)
            }
        }
    }
}

/// One route row: name + a compact inventory line (passes, poses seen, last surveyed).
private struct RouteRow: View {
    let route: RouteRecord
    let passCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(route.routeId)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts: [String] = []
        parts.append(passCount == 1 ? "1 pass" : "\(passCount) passes")
        if !route.checkpoints.isEmpty {
            parts.append("\(route.checkpoints.count) checkpoints")
        }
        parts.append("updated \(route.updatedAt.formatted(date: .abbreviated, time: .omitted))")
        return parts.joined(separator: " · ")
    }
}
