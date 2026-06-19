import CoreMotion
import SwiftUI

struct LivePositioningView: View {
    @AppStorage("liveProfileResource") private var profileResource = RouteProfile.bundledProfiles[0].resource

    @State private var controller: LivePositioningController?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let controller {
                LivePositioningContent(controller: controller)
            } else if let loadError {
                ContentUnavailableView(
                    "Live route unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                ProgressView("Loading route profile…")
            }
        }
        .navigationTitle("Live")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(RouteProfile.bundledProfiles, id: \.resource) { option in
                        Button {
                            switchProfile(to: option.resource)
                        } label: {
                            if option.resource == profileResource {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                } label: {
                    Label("Route", systemImage: "map")
                }
            }
        }
        .task(loadProfile)
        .onDisappear {
            controller?.stop()
        }
    }

    private func loadProfile() async {
        guard controller == nil, loadError == nil else { return }
        do {
            controller = try LivePositioningController(profile: RouteProfile.loadBundled(resource: profileResource))
        } catch {
            loadError = "Could not load the bundled route profile: \(error.localizedDescription)"
        }
    }

    private func switchProfile(to resource: String) {
        controller?.stop()
        controller = nil
        loadError = nil
        profileResource = resource
        Task { await loadProfile() }
    }
}

private struct LivePositioningContent: View {
    let controller: LivePositioningController
    @State private var pathData: RoutePathData?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                primaryCard
                controlsCard
                if let pathData { card { RouteMapView(controller: controller, pathData: pathData) } }
                routeTimelineCard
                routeOnlyCard
                diagnosticsCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .onAppear { pathData = RoutePathData.load(resource: controller.profile.sourceResource ?? "") }
    }

    private var primaryCard: some View {
        card {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Known route mode")
                            .font(.title2.bold())
                        Text(controller.profile.routeLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        statusPill
                        motionPill
                    }
                }

                HStack(alignment: .center, spacing: 20) {
                    progressRing
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Current segment")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(controller.currentSegmentLabel)
                            .font(.title3.bold())
                            .fixedSize(horizontal: false, vertical: true)
                        nextCheckpointPill
                    }
                    Spacer(minLength: 0)
                }

                if !controller.deviceMotionAvailable {
                    Label("Live matching needs Core Motion on a physical iPhone.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(Color(.systemGray5), lineWidth: 11)
            Circle()
                .trim(from: 0, to: min(1, max(0, controller.segmentProgress)))
                .stroke(
                    controller.isProgressStale ? Color(.systemGray3) : statusColor,
                    style: StrokeStyle(lineWidth: 11, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.25), value: controller.segmentProgress)
            VStack(spacing: 2) {
                Text(controller.progressPercentText)
                    .font(.title.bold().monospacedDigit())
                    .foregroundStyle(controller.isProgressStale ? .secondary : .primary)
                Text(controller.isProgressStale ? "last agreed" : "segment")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 126, height: 126)
    }

    private var statusPill: some View {
        Text(statusDisplayText)
            .font(.caption.bold())
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(statusColor.opacity(0.16), in: Capsule())
            .foregroundStyle(statusColor)
    }

    private var motionPill: some View {
        Label(controller.motionModeLabel, systemImage: motionModeIcon)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(motionModeColor.opacity(0.14), in: Capsule())
            .foregroundStyle(motionModeColor)
    }

    private var nextCheckpointPill: some View {
        HStack(spacing: 8) {
            Image(systemName: controller.isComplete ? "checkmark.circle.fill" : "mappin.and.ellipse")
            Text(controller.isComplete ? "Route finished" : "Next: \(controller.nextCheckpoint)")
                .fontWeight(.semibold)
        }
        .font(.subheadline)
        .foregroundStyle(statusColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private var routeTimelineCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Route timeline")
                    .font(.headline)

                VStack(spacing: 12) {
                    ForEach(controller.profile.anchors) { anchor in
                        timelineRow(anchor)
                    }
                }
            }
        }
    }

    private func timelineRow(_ anchor: RouteAnchor) -> some View {
        let state = checkpointState(for: anchor)
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(state.color.opacity(state == .upcoming ? 0.12 : 0.18))
                    .frame(width: 30, height: 30)
                Image(systemName: state.iconName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(state.color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(anchor.name)
                    .font(.subheadline.weight(state == .current ? .bold : .semibold))
                    .foregroundStyle(state == .upcoming ? .secondary : .primary)
                Text(state.label)
                    .font(.caption)
                    .foregroundStyle(state.color)
            }
            Spacer()
        }
    }

    private var controlsCard: some View {
        card {
            VStack(spacing: 10) {
                // Carry pose, user-selected: the runtime cannot yet detect
                // pocketing, and turn evidence must be off in pocket.
                Picker("Carry", selection: Binding(
                    get: { controller.livePose },
                    set: { controller.livePose = $0 }
                )) {
                    Text("Hand").tag(DevicePose.hand)
                    Text("Pocket").tag(DevicePose.pocket)
                }
                .pickerStyle(.segmented)
                .disabled(controller.isRunning)

                Button {
                    controller.startOrReset()
                } label: {
                    Label(startButtonTitle, systemImage: "location.fill")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!controller.deviceMotionAvailable)

                Button(role: .destructive) {
                    controller.stop()
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!controller.isRunning)
            }
        }
    }

    private var routeOnlyCard: some View {
        card {
            Label {
                Text(controller.limitationCopy)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    .foregroundStyle(.blue)
            }
        }
    }

    private var diagnosticsCard: some View {
        card {
            DisclosureGroup {
                VStack(spacing: 10) {
                    diagnosticRow("Motion mode", controller.motionModeLabel)
                    diagnosticRow("Recent steps", "\(controller.recentMotionStepCount)")
                    diagnosticRow("Mean user accel", String(format: "%.3f g", controller.motionMeanUserAcceleration))
                    diagnosticRow("Mean rotation", String(format: "%.3f rad/s", controller.motionMeanRotation))
                    diagnosticRow("Route samples", "\(controller.totalSampleCount)")
                    diagnosticRow("Detected steps", "\(controller.detectedSteps)")
                    diagnosticRow("Magnetic magnitude", String(format: "%.1f µT", controller.magneticMagnitude))
                    diagnosticRow("Mag std dev", String(format: "%.2f µT", controller.motionMagneticStdDev))
                    diagnosticRow("Mag calibration", calibrationLabel)
                    diagnosticRow("Global progress", percent(controller.globalProgress))
                    diagnosticRow("P(off route)", percent(controller.pOff))
                    diagnosticRow("Posterior spread", String(format: "%.0f bins", controller.posteriorStdBins))
                    diagnosticRow("Magnetic updates", "\(controller.magneticUpdates)")
                    diagnosticRow("Last window", controller.lastWindowStatus)
                    if let turn = controller.lastTurnLabel {
                        diagnosticRow("Last turn", turn)
                    }
                    if let reason = controller.lastAdvanceReason {
                        diagnosticRow("Last advance", reason)
                    }
                }
                .padding(.top, 12)
            } label: {
                Label("Diagnostics", systemImage: "waveform.path.ecg")
                    .font(.headline)
            }
        }
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.callout.monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var startButtonTitle: String {
        controller.isRunning || controller.totalSampleCount > 0 || controller.isComplete ? "Reset to Start" : "Start at Start"
    }

    private var statusDisplayText: String {
        if controller.isComplete { return "Complete" }
        if controller.statusText.hasPrefix("Near") { return "Near checkpoint" }
        if controller.statusText == "Starting at Start" { return "Ready" }
        return controller.statusText
    }

    private var calibrationLabel: String {
        switch controller.magneticAccuracy {
        case .uncalibrated: return "none"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        @unknown default: return "?"
        }
    }

    private var statusColor: Color {
        if controller.isComplete { return .green }
        if controller.statusText == "Off route?"
            || controller.statusText == "Phone moving" { return .red }
        if controller.statusText == "Low magnetic signal" { return .orange }
        if controller.statusText.hasPrefix("Near") { return .green }
        if controller.isRunning && controller.statusText == "Walking" { return .blue }
        return .secondary
    }

    private var motionModeColor: Color {
        switch controller.motionModeLabel {
        case "Walking": return .blue
        case "Phone moving": return .red
        case "Standing": return .secondary
        default: return .secondary
        }
    }

    private var motionModeIcon: String {
        switch controller.motionModeLabel {
        case "Walking": return "figure.walk"
        case "Phone moving": return "iphone.radiowaves.left.and.right"
        case "Standing": return "figure.stand"
        default: return "ellipsis"
        }
    }

    private func checkpointState(for anchor: RouteAnchor) -> CheckpointState {
        if controller.isComplete { return .complete }

        let activePosition = controller.activeSegmentPosition
        if !controller.isRunning && controller.totalSampleCount == 0 {
            return anchor.index == 0 ? .current : .upcoming
        }
        if anchor.index <= activePosition { return .complete }
        if anchor.index == activePosition + 1 { return .current }
        return .upcoming
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private enum CheckpointState {
    case complete
    case current
    case upcoming

    var color: Color {
        switch self {
        case .complete: return .green
        case .current: return .blue
        case .upcoming: return .secondary
        }
    }

    var iconName: String {
        switch self {
        case .complete: return "checkmark"
        case .current: return "location.fill"
        case .upcoming: return "circle.fill"
        }
    }

    var label: String {
        switch self {
        case .complete: return "Reached"
        case .current: return "Current target"
        case .upcoming: return "Upcoming"
        }
    }
}
