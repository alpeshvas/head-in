import SwiftUI

struct SessionsView: View {
    @State private var sessions: [SessionFile] = []

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
        .onAppear(perform: reload)
        .refreshable { reload() }
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
