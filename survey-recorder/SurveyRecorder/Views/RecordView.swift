import CoreMotion
import SwiftUI

struct RecordView: View {
    let controller: RecordingController
    let onDismiss: () -> Void

    @State private var confirmStop = false

    var body: some View {
        VStack(spacing: 24) {
            header
            Spacer()
            anchorButton
            undoButton
            Spacer()
            liveStats
            stopButton
        }
        .padding()
        .interactiveDismissDisabled()
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("\(controller.setup.venueId) / \(controller.setup.routeId)")
                .font(.headline)
            Text("\(controller.setup.direction.rawValue.capitalized) · \(controller.setup.devicePose.rawValue.capitalized)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
            Text("Anchored \(controller.anchorCount)/\(controller.setup.checkpoints.count)")
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
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
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
