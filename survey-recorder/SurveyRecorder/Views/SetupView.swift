import SwiftUI

struct SetupView: View {
    @AppStorage("venueId") private var venueId = ""
    @AppStorage("routeId") private var routeId = ""
    @AppStorage("floorId") private var floorId = ""
    @AppStorage("direction") private var direction = Direction.forward.rawValue
    @AppStorage("devicePose") private var devicePose = DevicePose.hand.rawValue
    @AppStorage("checkpointsText") private var checkpointsText = ""

    @State private var controller: RecordingController?
    @State private var startError: String?

    private var checkpoints: [String] {
        checkpointsText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var canStart: Bool {
        !venueId.trimmingCharacters(in: .whitespaces).isEmpty
            && !routeId.trimmingCharacters(in: .whitespaces).isEmpty
            && checkpoints.count >= 2
    }

    var body: some View {
        Form {
            Section("Route") {
                TextField("Venue ID", text: $venueId)
                TextField("Route ID", text: $routeId)
                TextField("Floor ID (metadata only)", text: $floorId)
                Picker("Direction", selection: $direction) {
                    ForEach(Direction.allCases) { d in
                        Text(d.rawValue.capitalized).tag(d.rawValue)
                    }
                }
                Picker("Device pose", selection: $devicePose) {
                    ForEach(DevicePose.allCases) { p in
                        Text(p.rawValue.capitalized).tag(p.rawValue)
                    }
                }
            }

            Section {
                TextField("One checkpoint per line", text: $checkpointsText, axis: .vertical)
                    .lineLimit(4...12)
                    .autocorrectionDisabled()
            } header: {
                Text("Checkpoints (in walking order)")
            } footer: {
                Text(checkpoints.count < 2
                    ? "At least 2 checkpoints required (route start and end)."
                    : "\(checkpoints.count) checkpoints")
            }

            Section {
                Button {
                    start()
                } label: {
                    Label("Start Recording", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .disabled(!canStart)
            } footer: {
                if let startError {
                    Text(startError).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Survey")
        .fullScreenCover(item: $controller) { controller in
            RecordView(controller: controller) {
                self.controller = nil
            }
        }
    }

    private func start() {
        let setup = RouteSetup(
            venueId: venueId.trimmingCharacters(in: .whitespaces),
            routeId: routeId.trimmingCharacters(in: .whitespaces),
            floorId: floorId.trimmingCharacters(in: .whitespaces),
            direction: Direction(rawValue: direction) ?? .forward,
            devicePose: DevicePose(rawValue: devicePose) ?? .hand,
            checkpoints: checkpoints
        )
        do {
            controller = try RecordingController(setup: setup)
            startError = nil
        } catch {
            startError = "Could not start session: \(error.localizedDescription)"
        }
    }
}

extension RecordingController: Identifiable {
    var id: URL { fileURL }
}
