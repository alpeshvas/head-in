import SwiftUI
import UniformTypeIdentifiers

struct SessionsView: View {
    @State private var sessions: [SessionFile] = []
    @State private var showDeleteAllConfirmation = false
    @State private var showBundleImporter = false
    @State private var isExportingBundle = false
    @State private var exportError: String?
    @State private var bundleShareURL: ShareableURL?
    @State private var importSummary: SurveyBundleSummary?
    @State private var importError: String?

    var body: some View {
        List {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "tray",
                    description: Text("Recorded survey sessions appear here. They are also visible in the Files app.")
                )
            }
            ForEach(sessions) { session in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.url.lastPathComponent)
                            .font(.callout)
                            .lineLimit(2)
                        Text("\(session.sizeString) · \(session.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShareLink(item: session.url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .onDelete(perform: delete)
        }
        .navigationTitle("Sessions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        exportBundle()
                    } label: {
                        Label("Export all as bundle", systemImage: "tray.and.arrow.up")
                    }
                    .disabled(sessions.isEmpty && !mapIsImported)

                    Button {
                        showBundleImporter = true
                    } label: {
                        Label("Import bundle…", systemImage: "tray.and.arrow.down")
                    }

                    Divider()

                    Button(role: .destructive) {
                        showDeleteAllConfirmation = true
                    } label: {
                        Label("Delete all sessions", systemImage: "trash")
                    }
                    .disabled(sessions.isEmpty)
                } label: {
                    Label("Manage", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "Delete all \(sessions.count) session\(sessions.count == 1 ? "" : "s")?",
            isPresented: $showDeleteAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete all", role: .destructive) {
                deleteAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every recorded survey from the app. Copies exported via the share sheet are unaffected.")
        }
        .onAppear(perform: reload)
        .refreshable { reload() }
        .fileImporter(
            isPresented: $showBundleImporter,
            allowedContentTypes: [UTType(filenameExtension: "jsonl") ?? UTType.json, UTType.json]
        ) { result in
            switch result {
            case .success(let url):
                do {
                    let summary = try SurveyBundle.importBundle(from: url)
                    importSummary = summary
                    importError = nil
                    reload()
                } catch {
                    importError = error.localizedDescription
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .sheet(item: $bundleShareURL) { wrap in
            VStack(spacing: 16) {
                Text("Survey bundle ready")
                    .font(.headline)
                Text(wrap.url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ShareLink(item: wrap.url) {
                    Label("Share / Save bundle", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button("Done") { bundleShareURL = nil }
                    .buttonStyle(.bordered)
            }
            .padding()
            .presentationDetents([.medium])
        }
        .alert("Bundle imported", isPresented: Binding(
            get: { importSummary != nil },
            set: { if !$0 { importSummary = nil } }
        )) {
            Button("OK", role: .cancel) { importSummary = nil }
        } message: {
            Text(importSummary?.description ?? "")
        }
        .alert("Could not import bundle", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "Unknown error")
        }
        .alert("Could not export bundle", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "Unknown error")
        }
        .overlay {
            if isExportingBundle {
                ProgressView("Building bundle…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var mapIsImported: Bool {
        FileManager.default.fileExists(atPath: VenueMap2DStore.importedMapURL.path)
    }

    private func exportBundle() {
        isExportingBundle = true
        exportError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try SurveyBundle.exportBundle()
                DispatchQueue.main.async {
                    isExportingBundle = false
                    bundleShareURL = ShareableURL(url: url)
                }
            } catch {
                DispatchQueue.main.async {
                    isExportingBundle = false
                    exportError = error.localizedDescription
                }
            }
        }
    }

    private func reload() {
        let dir = SessionWriter.sessionsDirectory
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        )) ?? []
        sessions = urls
            .filter { $0.pathExtension == "jsonl" }
            .map { SessionFile(url: $0) }
            .sorted { $0.date > $1.date }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            try? FileManager.default.removeItem(at: sessions[index].url)
        }
        reload()
    }

    private func deleteAll() {
        for session in sessions {
            try? FileManager.default.removeItem(at: session.url)
        }
        reload()
    }
}

struct SessionFile: Identifiable {
    let url: URL
    let size: Int
    let date: Date

    var id: URL { url }

    init(url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        size = values?.fileSize ?? 0
        date = values?.contentModificationDate ?? .distantPast
    }

    var sizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

private struct ShareableURL: Identifiable {
    let url: URL
    var id: URL { url }
}
