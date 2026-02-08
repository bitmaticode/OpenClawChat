import Foundation
import AVFoundation
import whisper

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

    var onSentence: ((String) -> Void)?
    var onFinal: ((String) -> Void)?

    private let modelFileName = "whisper-large-v3-turbo-q4_k.gguf"
    private let modelRemoteURL = URL(string: "https://huggingface.co/xkeyC/whisper-large-v3-turbo-gguf/resolve/main/model_q4_k.gguf")!

    private let sampleRate: Double = 16_000
    private let maxBufferSeconds: Double = 20
    private let silenceThreshold: Float = 0.015
    private let silenceTimeout: TimeInterval = 1.5
    private let transcriptionInterval: TimeInterval = 0.6
    private let minSamplesForTranscription = 1600

    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var whisperContext: OpaquePointer?

    private let bufferQueue = DispatchQueue(label: "openclaw.stt.buffer")
    private var sampleBuffer: [Float] = []
    private var lastSpeechAt: Date?
    private var hasSpeechSinceLastSend = false
    private var pendingText: String = ""
    private var committedText: String = ""
    private var lastTranscript: String = ""
    private var runningTranscription = false
    private var recordingActive = false
    private var modelReady = false
    private var transcriptionTimer: DispatchSourceTimer?

    deinit {
        if let ctx = whisperContext {
            whisper_free(ctx)
        }
    }

    func startStreaming() async throws {
        try await requestMicPermissionIfNeeded()
        try configureRecordingSession()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: inputFormat, to: desiredFormat)

        self.audioEngine = engine
        self.converter = converter

        resetState()
        startTimerIfNeeded()

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.bufferQueue.async {
                guard self.recordingActive else { return }
                guard let converter = self.converter else { return }
                guard let converted = self.convertBuffer(buffer, with: converter) else { return }
                guard let channel = converted.floatChannelData?.pointee else { return }

                let samples = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
                if samples.isEmpty { return }

                self.appendSamples(samples)
                let rms = self.rms(samples)
                if rms > self.silenceThreshold {
                    self.lastSpeechAt = Date()
                    self.hasSpeechSinceLastSend = true
                }
            }
        }

        try engine.start()

        isRecording = true
        bufferQueue.async { [weak self] in
            self?.recordingActive = true
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let modelURL = try await self.ensureModel()
                try self.loadWhisperContextIfNeeded(modelURL: modelURL)
                self.bufferQueue.async {
                    self.modelReady = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.stopStreaming(sendPending: false)
                }
            }
        }
    }

    func stopStreaming(sendPending: Bool = true) {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        converter = nil

        bufferQueue.async {
            self.recordingActive = false
            self.runningTranscription = false
            if sendPending {
                self.finalizeNow()
            }
            self.transcriptionTimer?.cancel()
            self.transcriptionTimer = nil
        }

        isRecording = false
        isTranscribing = false
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
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
    }

    private func resetState() {
        bufferQueue.async {
            self.sampleBuffer.removeAll()
            self.pendingText = ""
            self.committedText = ""
            self.lastTranscript = ""
            self.lastSpeechAt = nil
            self.hasSpeechSinceLastSend = false
        }
    }

    private func startTimerIfNeeded() {
        bufferQueue.async {
            self.transcriptionTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.bufferQueue)
            timer.schedule(deadline: .now() + self.transcriptionInterval, repeating: self.transcriptionInterval)
            timer.setEventHandler { [weak self] in
                self?.transcriptionTick()
            }
            timer.resume()
            self.transcriptionTimer = timer
        }
    }

    private func transcriptionTick() {
        guard recordingActive else { return }

        checkAutoSendIfNeeded()
        guard modelReady else { return }
        guard !runningTranscription else { return }
        guard sampleBuffer.count >= minSamplesForTranscription else { return }

        let ctx = whisperContext
        guard let ctx else { return }

        runningTranscription = true
        DispatchQueue.main.async {
            self.isTranscribing = true
        }
        let windowSamples = snapshotSamples()

        DispatchQueue.global(qos: .userInitiated).async {
            let text = try? Self.runWhisper(ctx: ctx, samples: windowSamples)
            self.bufferQueue.async {
                self.runningTranscription = false
                DispatchQueue.main.async {
                    self.isTranscribing = false
                }
                if let text {
                    self.bufferQueue.async {
                        self.handleTranscript(text)
                    }
                }
            }
        }
    }

    private func snapshotSamples() -> [Float] {
        let maxSamples = Int(sampleRate * maxBufferSeconds)
        if sampleBuffer.count > maxSamples {
            sampleBuffer.removeFirst(sampleBuffer.count - maxSamples)
        }
        if sampleBuffer.count <= maxSamples {
            return sampleBuffer
        }
        return Array(sampleBuffer.suffix(maxSamples))
    }

    private func appendSamples(_ samples: [Float]) {
        sampleBuffer.append(contentsOf: samples)
        let maxSamples = Int(sampleRate * maxBufferSeconds)
        if sampleBuffer.count > maxSamples {
            sampleBuffer.removeFirst(sampleBuffer.count - maxSamples)
        }
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0) { $0 + $1 * $1 }
        return sqrt(sum / Float(samples.count))
    }

    private func handleTranscript(_ text: String) {
        guard !text.isEmpty else { return }
        var delta = text
        if !lastTranscript.isEmpty, text.hasPrefix(lastTranscript) {
            delta = String(text.dropFirst(lastTranscript.count))
        } else if !lastTranscript.isEmpty {
            committedText = ""
            pendingText = ""
        }

        lastTranscript = text
        pendingText += delta

        while let idx = boundaryIndex(in: pendingText) {
            let sentence = String(pendingText[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
            pendingText.removeSubrange(..<idx)
            if !sentence.isEmpty {
                committedText = (committedText + " " + sentence).trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    self.onSentence?(sentence)
                }
            }
        }
    }

    private func boundaryIndex(in s: String) -> String.Index? {
        let boundaries: [Character] = ["\n", ".", "?", "!"]
        guard let last = s.lastIndex(where: { boundaries.contains($0) }) else { return nil }
        return s.index(after: last)
    }

    private func checkAutoSendIfNeeded() {
        guard hasSpeechSinceLastSend else { return }
        guard let last = lastSpeechAt else { return }
        if Date().timeIntervalSince(last) >= silenceTimeout {
            finalizeNow()
        }
    }

    private func finalizeNow() {
        let final = (committedText + " " + pendingText)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !final.isEmpty else {
            hasSpeechSinceLastSend = false
            return
        }

        committedText = ""
        pendingText = ""
        lastTranscript = ""
        lastSpeechAt = nil
        hasSpeechSinceLastSend = false
        sampleBuffer.removeAll()

        DispatchQueue.main.async {
            self.onFinal?(final)
        }
    }

    private func convertBuffer(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        if error != nil || outBuffer.frameLength == 0 {
            return nil
        }

        return outBuffer
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
