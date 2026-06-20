import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class CheckpointAudioRecorder {
    private(set) var isRecording = false
    private(set) var recordingFileName: String?

    @ObservationIgnored private var recorder: AVAudioRecorder?

    func startRecording(fileName: String) async throws {
        guard !isRecording else { return }
        guard await requestPermission() else { throw CheckpointAudioError.microphoneDenied }

        try FileManager.default.createDirectory(at: VenueMap2DStore.checkpointAudioDirectory, withIntermediateDirectories: true)
        let url = VenueMap2DStore.checkpointAudioURL(fileName: fileName)
        try? FileManager.default.removeItem(at: url)

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.prepareToRecord()
        guard recorder.record() else { throw CheckpointAudioError.couldNotStart }
        self.recorder = recorder
        recordingFileName = fileName
        isRecording = true
    }

    func stopRecording() {
        recorder?.stop()
        recorder = nil
        recordingFileName = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}

@MainActor
final class CheckpointAudioPlayer {
    private var player: AVAudioPlayer?
    private var lastPlayedCheckpointID: String?

    func play(checkpoint: Checkpoint2D, force: Bool = false) {
        guard let fileName = checkpoint.audioFileName else { return }
        guard force || checkpoint.id != lastPlayedCheckpointID else { return }
        let url = VenueMap2DStore.checkpointAudioURL(fileName: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            player?.play()
            lastPlayedCheckpointID = checkpoint.id
        } catch {
            player = nil
        }
    }

    func play(fileName: String) throws {
        let url = VenueMap2DStore.checkpointAudioURL(fileName: fileName)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        player = try AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        player?.play()
    }

    func resetCheckpointGate() {
        lastPlayedCheckpointID = nil
    }
}

enum CheckpointAudioError: LocalizedError {
    case microphoneDenied
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is required to record checkpoint audio."
        case .couldNotStart:
            return "Could not start checkpoint audio recording."
        }
    }
}
