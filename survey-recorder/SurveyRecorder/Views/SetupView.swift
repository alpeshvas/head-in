import SwiftUI

struct SetupView: View {
    @AppStorage("venueId") private var venueId = ""
    @AppStorage("routeId") private var routeId = ""
    @AppStorage("floorId") private var floorId = ""
    @AppStorage("direction") private var direction = Direction.forward.rawValue
    @AppStorage("devicePose") private var devicePose = DevicePose.hand.rawValue
    @AppStorage("passType") private var passType = PassType.normal.rawValue
    @AppStorage("recordGroundTruth") private var recordGroundTruth = false
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
                Picker("Pass type", selection: $passType) {
                    ForEach(PassType.surveyCases) { type in
                        Text(type.label).tag(type.rawValue)
                    }
                }
            } header: {
                Text("Pass type")
            } footer: {
                Text(PassType(rawValue: passType)?.isNegative == true
                    ? "Negative pass — used to test that the matcher correctly rejects this. It should NOT track as a clean route walk."
                    : "Clean route walk for building fingerprints.")
            }

            Section {
                Toggle("Record ground truth (ARKit)", isOn: $recordGroundTruth)
            } header: {
                Text("Ground truth")
            } footer: {
                Text(ARPoseRecorder.isSupported
                    ? "Surveyor-only. Uses the camera to log a precise 6-DoF trajectory for offline evaluation and training. Never used in the shipped tour app. Hold the phone so the camera sees the space; point at textured surfaces, not blank walls."
                    : "AR world tracking is not supported on this device; ground truth will be skipped.")
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
            passType: PassType(rawValue: passType) ?? .normal,
            recordGroundTruth: recordGroundTruth,
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
