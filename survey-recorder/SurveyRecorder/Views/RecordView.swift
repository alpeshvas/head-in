import CoreMotion
import SwiftUI

struct RecordView: View {
    let controller: RecordingController
    let onDismiss: () -> Void

    @State private var confirmStop = false
    @State private var pendingName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            header
            Spacer()
            if controller.isAdHoc {
                adHocCheckpointControls
            } else {
                anchorButton
            }
            undoButton
            Spacer()
            liveStats
            stopButton
        }
        .padding()
        .interactiveDismissDisabled()
    }

    private var adHocCheckpointControls: some View {
        VStack(spacing: 12) {
            TextField("Next checkpoint name (optional)", text: $pendingName)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($nameFocused)
                .onSubmit { nameFocused = false }

            Button {
                nameFocused = false
                controller.dropCheckpoint(pendingName: pendingName)
                pendingName = ""
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 40))
                    Text("Drop checkpoint")
                        .font(.title2.bold())
                    Text(pendingName.trimmingCharacters(in: .whitespaces).isEmpty
                        ? "Auto-named “Checkpoint \(controller.anchorCount + 1)”"
                        : "Named “\(pendingName.trimmingCharacters(in: .whitespaces))”")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 180)
            }
            .buttonStyle(.borderedProminent)

            if !controller.recordedCheckpoints.isEmpty {
                Text(controller.recordedCheckpoints.enumerated()
                    .map { "\($0.offset + 1). \($0.element)" }
                    .joined(separator: "   "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("\(controller.setup.venueId) / \(controller.setup.routeId)")
                .font(.headline)
            Text("\(controller.setup.direction.rawValue.capitalized) · \(controller.setup.devicePose.rawValue.capitalized)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if controller.setup.passType.isNegative {
                Label("Negative pass: \(controller.setup.passType.label)", systemImage: "xmark.octagon.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }
            if !controller.deviceMotionAvailable {
                Label("Device motion unavailable on this device", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var anchorButton: some View {
        Button {
            controller.tapAnchor()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 44))
                if let next = controller.nextCheckpointName {
                    Text("Anchor")
                        .font(.title2.bold())
                    Text(next)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                } else {
                    Text("All checkpoints anchored")
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)
        }
        .buttonStyle(.borderedProminent)
        .tint(controller.nextCheckpointName == nil ? .gray : .blue)
        .disabled(controller.nextCheckpointName == nil)
    }

    private var undoButton: some View {
        Button("Undo last anchor", systemImage: "arrow.uturn.backward") {
            controller.undoAnchor()
        }
        .font(.subheadline)
        .disabled(controller.anchorCount == 0)
    }

    private var liveStats: some View {
        VStack(spacing: 6) {
            Text(controller.isAdHoc
                ? "Dropped \(controller.anchorCount)"
                : "Anchored \(controller.anchorCount)/\(controller.setup.checkpoints.count)")
                .font(.title3.monospacedDigit())

            HStack(spacing: 16) {
                stat("Elapsed", elapsedString)
                stat("Mag", String(format: "%.1f µT", controller.magneticMagnitude))
                stat("Steps", "\(controller.steps)")
            }

            HStack(spacing: 16) {
                stat("Samples", "\(controller.deviceMotionCount)")
                stat("Calibration", calibrationLabel)
            }

            if controller.setup.recordGroundTruth {
                HStack(spacing: 16) {
                    stat("Ground truth", controller.groundTruthStatus)
                    stat("AR poses", "\(controller.arPoseCount)")
                }
                .foregroundStyle(groundTruthColor)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var groundTruthColor: Color {
        switch controller.groundTruthStatus {
        case "tracking": return .green
        case "off", "starting": return .secondary
        default: return .orange
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }

    private var elapsedString: String {
        let seconds = Int(Date().timeIntervalSince(controller.startedAt))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
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

    private var stopButton: some View {
        Button(role: .destructive) {
            confirmStop = true
        } label: {
            Label("Stop & Save", systemImage: "stop.circle.fill")
                .frame(maxWidth: .infinity)
                .font(.headline)
        }
        .buttonStyle(.bordered)
        .confirmationDialog("Stop recording?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop & Save", role: .destructive) {
                controller.stop()
                onDismiss()
            }
        }
    }
}
