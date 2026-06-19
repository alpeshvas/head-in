import SwiftUI

/// Configures a recording. Two modes:
///  - **New route** (`route == nil`): full editor; venue field suggests existing
///    venues so you don't fork a typo'd duplicate.
///  - **New pass** (`route != nil`): venue/route/checkpoints come from the route
///    and are read-only; you only pick the pass parameters.
struct SetupView: View {
    /// When set, this is a new pass on an existing route (identity locked).
    let route: RouteRecord?

    @Environment(RouteRegistry.self) private var registry
    @Environment(\.dismiss) private var dismiss

    @State private var venueId = ""
    @State private var routeId = ""
    @State private var floorId = ""
    @State private var checkpointsText = ""

    // Pass parameters double as "last used" defaults for the next new route.
    @AppStorage("direction") private var direction = Direction.forward.rawValue
    @AppStorage("devicePose") private var devicePose = DevicePose.hand.rawValue
    @AppStorage("passType") private var passType = PassType.normal.rawValue
    @AppStorage("recordGroundTruth") private var recordGroundTruth = false

    @State private var controller: RecordingController?
    @State private var startError: String?
    @State private var didSeed = false

    private var isNewPass: Bool { route != nil }

    private var checkpoints: [String] {
        checkpointsText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var canStart: Bool {
        if isNewPass { return true }
        return !venueId.trimmingCharacters(in: .whitespaces).isEmpty
            && !routeId.trimmingCharacters(in: .whitespaces).isEmpty
            && (checkpoints.count >= 2 || checkpoints.isEmpty)
    }

    var body: some View {
        Form {
            if isNewPass {
                routeHeaderSection
            } else {
                newRouteSection
            }

            passTypeSection
            groundTruthSection

            if !isNewPass {
                checkpointsSection
            }

            startSection
        }
        .navigationTitle(isNewPass ? "New Pass" : "New Route")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .onAppear(perform: seedFromRouteOnce)
        .fullScreenCover(item: $controller) { controller in
            RecordView(controller: controller) { finish(controller) }
        }
    }

    // MARK: sections

    private var routeHeaderSection: some View {
        Section {
            LabeledContent("Venue", value: route?.venueId ?? "")
            LabeledContent("Route", value: route?.routeId ?? "")
            if let route, !route.checkpoints.isEmpty {
                LabeledContent("Checkpoints", value: "\(route.checkpoints.count)")
            }
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
        } header: {
            Text("Route")
        } footer: {
            if let route, route.checkpoints.isEmpty {
                Text("This route has no checkpoints yet — you'll name them while walking (ad-hoc).")
            } else {
                Text("Checkpoints are reused from the route — tap through them in order as you walk.")
            }
        }
    }

    private var newRouteSection: some View {
        Section {
            TextField("Venue ID", text: $venueId)
                .autocorrectionDisabled()
            if !registry.venueNames.isEmpty {
                venueSuggestions
            }
            TextField("Route ID", text: $routeId)
                .autocorrectionDisabled()
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
        } header: {
            Text("Route")
        } footer: {
            Text("Pick an existing venue to keep its routes grouped together.")
        }
    }

    private var venueSuggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(registry.venueNames, id: \.self) { name in
                    Button {
                        venueId = name
                    } label: {
                        Text(name)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                venueId == name ? Color.accentColor : Color(.secondarySystemFill),
                                in: Capsule()
                            )
                            .foregroundStyle(venueId == name ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var passTypeSection: some View {
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
    }

    private var groundTruthSection: some View {
        Section {
            Toggle("Record ground truth (ARKit)", isOn: $recordGroundTruth)
        } header: {
            Text("Ground truth")
        } footer: {
            Text(ARPoseRecorder.isSupported
                ? "Surveyor-only. Uses the camera to log a precise 6-DoF trajectory for offline evaluation and training. Never used in the shipped tour app. Hold the phone so the camera sees the space; point at textured surfaces, not blank walls."
                : "AR world tracking is not supported on this device; ground truth will be skipped.")
        }
    }

    private var checkpointsSection: some View {
        Section {
            TextField("One checkpoint per line", text: $checkpointsText, axis: .vertical)
                .lineLimit(4...12)
                .autocorrectionDisabled()
        } header: {
            Text("Checkpoints (in walking order)")
        } footer: {
            if checkpoints.isEmpty {
                Text("Leave empty to name checkpoints while surveying — drop and name each one as you reach it.")
            } else if checkpoints.count < 2 {
                Text("Add at least 2, or clear the field to name them while surveying.")
            } else {
                Text("\(checkpoints.count) checkpoints")
            }
        }
    }

    private var startSection: some View {
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

    // MARK: actions

    private func seedFromRouteOnce() {
        guard !didSeed else { return }
        didSeed = true
        if let route {
            venueId = route.venueId
            routeId = route.routeId
            floorId = route.floorId
            checkpointsText = route.checkpoints.joined(separator: "\n")
            direction = route.lastDirection
            devicePose = route.lastPose
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
            let controller = try RecordingController(setup: setup)
            registry.upsert(from: setup)   // persist the route before recording
            self.controller = controller
            startError = nil
        } catch {
            startError = "Could not start session: \(error.localizedDescription)"
        }
    }

    private func finish(_ controller: RecordingController) {
        // Ad-hoc pass discovered the checkpoint names during the walk — fold them
        // into the route so the next pass gets the fast predefined tap-through.
        if controller.isAdHoc, controller.recordedCheckpoints.count >= 2 {
            registry.setCheckpoints(
                controller.recordedCheckpoints,
                venueId: controller.setup.venueId,
                routeId: controller.setup.routeId
            )
        }
        self.controller = nil
        dismiss()
    }
}

extension RecordingController: Identifiable {
    var id: URL { fileURL }
}
