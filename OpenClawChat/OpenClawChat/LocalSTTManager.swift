import Foundation
import AVFoundation
import whisper

@MainActor
final class LocalSTTManager: ObservableObject {
    enum STTError: LocalizedError {
        case micPermissionDenied
        case recordingFailed
        case noRecording
        case modelDownloadFailed
        case modelLoadFailed
        case transcriptionFailed

        var errorDescription: String? {
            switch self {
            case .micPermissionDenied: return "Permiso de micrófono denegado"
            case .recordingFailed: return "No pude iniciar la grabación"
            case .noRecording: return "No hay grabación disponible"
            case .modelDownloadFailed: return "No pude descargar el modelo Whisper"
            case .modelLoadFailed: return "No pude cargar el modelo Whisper"
            case .transcriptionFailed: return "Falló la transcripción local"
            }
        }
    }

    @Published var isRecording = false
    @Published var isTranscribing = false

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var whisperContext: OpaquePointer?

    private let modelFileName = "whisper-large-v3-turbo-q4_k.gguf"
    private let modelRemoteURL = URL(string: "https://huggingface.co/xkeyC/whisper-large-v3-turbo-gguf/resolve/main/model_q4_k.gguf")!

    deinit {
        if let ctx = whisperContext {
            whisper_free(ctx)
        }
    }

    func startRecording() async throws {
        try await requestMicPermissionIfNeeded()
        try configureRecordingSession()

        let url = try makeRecordingURL()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = false
        recorder.prepareToRecord()

        guard recorder.record() else {
            throw STTError.recordingFailed
        }

        self.recorder = recorder
        self.recordingURL = url
        isRecording = true
    }

    func stopAndTranscribe() async throws -> String {
        guard isRecording else { throw STTError.noRecording }

        recorder?.stop()
        isRecording = false

        let url = recordingURL
        recorder = nil

        try configurePlaybackSession()

        guard let audioURL = url else { throw STTError.noRecording }

        isTranscribing = true
        defer { isTranscribing = false }

        let modelURL = try await ensureModel()
        try loadWhisperContextIfNeeded(modelURL: modelURL)

        let samples = try loadPCMFloatSamples(from: audioURL)

        return try await Task.detached(priority: .userInitiated) { [samples, whisperContext] in
            guard let ctx = whisperContext else { throw STTError.modelLoadFailed }
            return try Self.runWhisper(ctx: ctx, samples: samples)
        }.value
    }

    private func requestMicPermissionIfNeeded() async throws {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return
        case .denied:
            throw STTError.micPermissionDenied
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                session.requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
            if !granted {
                throw STTError.micPermissionDenied
            }
        @unknown default:
            throw STTError.micPermissionDenied
        }
    }

    private func configureRecordingSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true)
    }

    private func configurePlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
    }

    private func makeRecordingURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("openclaw-recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("stt-\(UUID().uuidString).caf")
    }

    private func ensureModel() async throws -> URL {
        let fm = FileManager.default
        let dir = try modelDirectory()
        let dest = dir.appendingPathComponent(modelFileName)

        if fm.fileExists(atPath: dest.path) {
            return dest
        }

        let (tmpURL, _) = try await URLSession.shared.download(from: modelRemoteURL)
        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: tmpURL, to: dest)
            return dest
        } catch {
            throw STTError.modelDownloadFailed
        }
    }

    private func modelDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = root.appendingPathComponent("openclaw/models", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadWhisperContextIfNeeded(modelURL: URL) throws {
        guard whisperContext == nil else { return }
        var params = whisper_context_default_params()
        let ctx = whisper_init_from_file_with_params(modelURL.path, params)
        guard ctx != nil else { throw STTError.modelLoadFailed }
        whisperContext = ctx
    }

    private func loadPCMFloatSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw STTError.transcriptionFailed
        }

        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?.pointee else {
            throw STTError.transcriptionFailed
        }

        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        if samples.isEmpty { throw STTError.transcriptionFailed }
        return samples
    }

    nonisolated private static func runWhisper(ctx: OpaquePointer, samples: [Float]) throws -> String {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.n_threads = Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount)))

        let lang = strdup("es")
        if let lang {
            params.language = UnsafePointer(lang)
        }

        let ret: Int32 = samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return -1 }
            return whisper_full(ctx, params, base, Int32(buffer.count))
        }

        if let lang { free(lang) }
        guard ret == 0 else { throw STTError.transcriptionFailed }

        let count = whisper_full_n_segments(ctx)
        var text = ""
        for i in 0..<count {
            if let cstr = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: cstr)
            }
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
