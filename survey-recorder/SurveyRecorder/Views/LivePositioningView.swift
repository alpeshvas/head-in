import CoreMotion
import SwiftUI

struct LivePositioningView: View {
    @AppStorage("liveProfileResource") private var profileResource = RouteProfile.bundledProfiles[0].resource
    @Environment(RouteRegistry.self) private var registry

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
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Instrument.ink, for: .navigationBar)
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
        .onAppear(perform: applyDisplayNames)
        .onDisappear {
            controller?.stop()
        }
    }

    private func loadProfile() async {
        guard controller == nil, loadError == nil else { return }
        do {
            controller = try LivePositioningController(profile: RouteProfile.loadBundled(resource: profileResource))
            applyDisplayNames()
        } catch {
            loadError = "Could not load the bundled route profile: \(error.localizedDescription)"
        }
    }

    /// Bridge survey-registry checkpoint names onto the Live display when a route
    /// with the same venue/route and the same number of anchors exists. Re-runs
    /// on appear so renames made in the Survey tab show up here.
    private func applyDisplayNames() {
        guard let controller else { return }
        let r = controller.profile.route
        if let record = registry.record(venueId: r.venueId, routeId: r.routeId),
           record.checkpoints.count == controller.profile.anchors.count {
            controller.checkpointDisplayNames = record.checkpoints
        } else {
            controller.checkpointDisplayNames = nil
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
                routeOnlyCard
                diagnosticsCard
            }
            .padding()
        }
        .background(InstrumentBackground())
        .environment(\.colorScheme, .dark)
        .onAppear { pathData = RoutePathData.load(resource: controller.profile.sourceResource ?? "") }
    }

    private var primaryCard: some View {
        card {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("KNOWN ROUTE").monoTag()
                        Text(controller.profile.routeLabel)
                            .font(.system(size: 19, weight: .bold, design: .monospaced))
                            .foregroundStyle(Instrument.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 7) {
                        InstrumentChip(text: statusDisplayText, color: statusColor)
                        InstrumentChip(text: controller.motionModeLabel, color: motionModeColor, icon: motionModeIcon)
                    }
                }

                HStack(alignment: .center, spacing: 20) {
                    progressRing
                    VStack(alignment: .leading, spacing: 9) {
                        Text("CURRENT SEGMENT").monoTag()
                        Text(controller.currentSegmentLabel)
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundStyle(Instrument.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        nextCheckpointPill
                    }
                    Spacer(minLength: 0)
                }

                if !controller.deviceMotionAvailable {
                    Label("Live matching needs Core Motion on a physical iPhone.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Instrument.amber)
                }
            }
        }
    }

    private var progressRing: some View {
        ZStack {
            Circle().stroke(Instrument.hairline, lineWidth: 9)
            Circle()
                .trim(from: 0, to: min(1, max(0, controller.segmentProgress)))
                .stroke(
                    controller.isProgressStale ? Instrument.steel : statusColor,
                    style: StrokeStyle(lineWidth: 9, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: controller.isProgressStale ? .clear : statusColor.opacity(0.6), radius: 5)
                .animation(.easeOut(duration: 0.25), value: controller.segmentProgress)
            VStack(spacing: 2) {
                Text(controller.progressPercentText)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundStyle(controller.isProgressStale ? Instrument.textSecondary : Instrument.textPrimary)
                Text(controller.isProgressStale ? "LAST AGREED" : "SEGMENT").monoTag()
            }
        }
        .frame(width: 122, height: 122)
    }

    private var nextCheckpointPill: some View {
        HStack(spacing: 7) {
            Image(systemName: controller.isComplete ? "checkmark.circle.fill" : "scope")
                .font(.system(size: 11, weight: .bold))
            Text(controller.isComplete ? "ROUTE FINISHED" : "NEXT · \(controller.nextCheckpoint)")
                .font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(0.8)
                .lineLimit(1).truncationMode(.tail)
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(statusColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(statusColor.opacity(0.4), lineWidth: 1))
    }

    private var controlsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                // Carry pose, user-selected: the runtime cannot yet detect
                // pocketing, and turn evidence must be off in pocket.
                Text("CARRY MODE").monoTag()
                Picker("Carry", selection: Binding(
                    get: { controller.livePose },
                    set: { controller.livePose = $0 }
                )) {
                    Text("Hand").tag(DevicePose.hand)
                    Text("Pocket").tag(DevicePose.pocket)
                }
                .pickerStyle(.segmented)
                .disabled(controller.isRunning)

                HStack(spacing: 10) {
                    Button { controller.startOrReset() } label: {
                        Label(startButtonTitle, systemImage: "location.fill")
                    }
                    .buttonStyle(InstrumentButtonStyle(tint: Instrument.phosphor, prominent: true))
                    .disabled(!controller.deviceMotionAvailable)

                    Button { controller.stop() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(InstrumentButtonStyle(tint: Instrument.coral, prominent: false))
                    .disabled(!controller.isRunning)
                    .opacity(controller.isRunning ? 1 : 0.4)
                    .frame(maxWidth: 130)
                }
            }
        }
    }

    private var routeOnlyCard: some View {
        card {
            Label {
                Text(controller.limitationCopy)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Instrument.textSecondary)
            } icon: {
                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    .foregroundStyle(Instrument.phosphor)
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
                Label("DIAGNOSTICS", systemImage: "waveform.path.ecg")
                    .font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(1.0)
                    .foregroundStyle(Instrument.textSecondary)
            }
            .tint(Instrument.textSecondary)
        }
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Instrument.textTertiary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Instrument.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().instrumentPanel()
    }

    private var startButtonTitle: String {
        controller.isRunning || controller.totalSampleCount > 0 || controller.isComplete ? "Restart" : "Start Tracking"
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
        if controller.isComplete { return Instrument.phosphor }
        if controller.statusText == "Off route?"
            || controller.statusText == "Phone moving" { return Instrument.coral }
        if controller.statusText == "Low magnetic signal"
            || controller.statusText == "Holding position" { return Instrument.amber }
        if controller.statusText.hasPrefix("Near") { return Instrument.phosphor }
        if controller.isRunning && controller.statusText == "Walking" { return Instrument.phosphor }
        return Instrument.textSecondary
    }

    private var motionModeColor: Color {
        switch controller.motionModeLabel {
        case "Walking": return Instrument.phosphor
        case "Phone moving": return Instrument.coral
        case "Standing": return Instrument.textSecondary
        default: return Instrument.textTertiary
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

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
