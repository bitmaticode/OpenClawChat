//
//  LocalSTTManager.swift
//  OpenClawChat
//
//  On-device Speech-to-Text using WhisperKit (CoreML + Apple Neural Engine).
//  Architecture: AVAudioEngine capture → ring buffer → WhisperKit transcribe.
//
//  Key design decisions (learned from LAIA repo):
//  - WhisperKit instance is created ONCE and kept alive for the app's lifetime
//  - Model download + CoreML compilation happens only on first ever use
//  - No idle unloading (avoids expensive re-compilation)
//  - Own audio capture via AVAudioEngine (not WhisperKit's startRecordingLive)
//

import Foundation
import AVFoundation
import os

#if canImport(WhisperKit)
import WhisperKit
#endif

// MARK: - Audio Ring Buffer

/// Thread-safe ring buffer for real-time 16kHz mono audio samples.
final class AudioRingBuffer: @unchecked Sendable {
    static let sampleRate: Double = 16000
    static let bufferDurationSeconds: Double = 30.0
    static let capacity: Int = Int(sampleRate * bufferDurationSeconds)

    private let storage: UnsafeMutableBufferPointer<Float>
    private var writeIdx = 0
    private var readIdx = 0
    private var available = 0
    private let lock = OSAllocatedUnfairLock()

    var count: Int { lock.withLock { available } }

    init() {
        storage = .allocate(capacity: Self.capacity)
        storage.initialize(repeating: 0)
    }

    deinit { storage.deallocate() }

    func write(_ samples: UnsafeBufferPointer<Float>) {
        lock.withLock {
            for s in samples {
                storage[writeIdx] = s
                writeIdx = (writeIdx + 1) % Self.capacity
                if available < Self.capacity {
                    available += 1
                } else {
                    readIdx = (readIdx + 1) % Self.capacity
                }
            }
        }
    }

    func readAll() -> [Float] {
        lock.withLock {
            guard available > 0 else { return [] }
            var out = [Float](repeating: 0, count: available)
            for i in 0..<available {
                out[i] = storage[(readIdx + i) % Self.capacity]
            }
            readIdx = (readIdx + available) % Self.capacity
            available = 0
            return out
        }
    }

    func peekLast(_ n: Int) -> [Float] {
        lock.withLock {
            let count = min(n, available)
            guard count > 0 else { return [] }
            var out = [Float](repeating: 0, count: count)
            let start = (readIdx + available - count + Self.capacity) % Self.capacity
            for i in 0..<count {
                out[i] = storage[(start + i) % Self.capacity]
            }
            return out
        }
    }

    func clear() {
        lock.withLock {
            writeIdx = 0
            readIdx = 0
            available = 0
        }
    }
}

// MARK: - Audio Capture Engine

/// AVAudioEngine-based capture at 16kHz mono, feeding an AudioRingBuffer.
final class AudioCaptureEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let ringBuffer: AudioRingBuffer
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private let logger = Logger(subsystem: "ai.openclaw.chat", category: "AudioCapture")
    private var _isCapturing = false

    var isCapturing: Bool { _isCapturing }
    var onAudioLevel: ((Float) -> Void)?

    init(ringBuffer: AudioRingBuffer) {
        self.ringBuffer = ringBuffer
        self.targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: AudioRingBuffer.sampleRate,
            channels: 1
        )!
    }

    func setup() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetoothA2DP]
        )
        try session.setPreferredSampleRate(AudioRingBuffer.sampleRate)
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        if inputFormat.sampleRate != targetFormat.sampleRate ||
           inputFormat.channelCount != targetFormat.channelCount {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        }
    }

    func start() throws {
        guard !_isCapturing else { return }
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)

        engine.inputNode.installTap(onBus: 0, bufferSize: 1600, format: inputFormat) {
            [weak self] pcmBuffer, _ in
            self?.processCapturedBuffer(pcmBuffer)
        }

        engine.prepare()
        try engine.start()
        _isCapturing = true
    }

    func stop() {
        guard _isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        _isCapturing = false
    }

    private func processCapturedBuffer(_ pcmBuffer: AVAudioPCMBuffer) {
        let processBuffer: AVAudioPCMBuffer
        if let conv = converter {
            let ratio = targetFormat.sampleRate / pcmBuffer.format.sampleRate
            let outCap = AVAudioFrameCount(Double(pcmBuffer.frameLength) * ratio)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else { return }
            var error: NSError?
            conv.convert(to: outBuf, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return pcmBuffer
            }
            if error != nil { return }
            processBuffer = outBuf
        } else {
            processBuffer = pcmBuffer
        }

        guard let channelData = processBuffer.floatChannelData?[0] else { return }
        let length = Int(processBuffer.frameLength)
        let ptr = UnsafeBufferPointer(start: channelData, count: length)
        ringBuffer.write(ptr)

        var rms: Float = 0
        for i in 0..<length { rms += channelData[i] * channelData[i] }
        rms = sqrt(rms / Float(length))
        onAudioLevel?(rms)
    }

    func setupInterruptionHandling(onResume: @escaping () -> Void) {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
            if type == .ended {
                try? self?.start()
                onResume()
            }
        }
    }
}

// MARK: - LocalSTTManager

@MainActor
final class LocalSTTManager: ObservableObject {

    // MARK: Errors

    enum STTError: LocalizedError {
        case micPermissionDenied
        case modelLoadFailed(String)
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .micPermissionDenied: return "Permiso de micrófono denegado"
            case .modelLoadFailed(let d): return "No pude cargar Whisper: \(d)"
            case .transcriptionFailed(let d): return "Transcripción fallida: \(d)"
            }
        }
    }

    // MARK: Published state

    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isLoadingModel = false
    @Published var isDownloadingModel = false
    @Published var downloadProgress: Double = 0
    @Published var statusMessage = ""
    @Published var audioLevel: Float = 0

    // MARK: Callbacks

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?

    // MARK: Configuration

    /// Which model to use. "openai_whisper-small" is a good balance for iOS.
    static let whisperModel = "openai_whisper-small"

    private let silenceThreshold: Float = 0.008
    private let silenceTimeout: TimeInterval = 1.5
    private let transcriptionInterval: TimeInterval = 1.0
    private let language = "es"

    // MARK: Internal components

    private let ringBuffer = AudioRingBuffer()
    private lazy var captureEngine = AudioCaptureEngine(ringBuffer: ringBuffer)
    private let logger = Logger(subsystem: "ai.openclaw.chat", category: "STT")

    #if canImport(WhisperKit)
    /// Singleton WhisperKit instance — created once, kept alive for app lifetime.
    /// This avoids re-downloading and re-compiling CoreML models on every mic toggle.
    private static var sharedWhisperKit: WhisperKit?
    private static var isModelLoading = false
    #endif

    private var transcriptionTask: Task<Void, Never>?
    private var lastSpeechAt: Date?
    private var accumulatedSamples: [Float] = []
    private var lastEmittedText = ""

    // MARK: - Public API

    func startStreaming() async throws {
        try await requestMicPermission()
        try await ensureModelLoaded()

        try captureEngine.setup()
        captureEngine.onAudioLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.audioLevel = level
            }
        }
        captureEngine.setupInterruptionHandling { [weak self] in
            Task { @MainActor [weak self] in
                self?.logger.info("Audio resumed after interruption")
            }
        }

        try captureEngine.start()
        ringBuffer.clear()
        accumulatedSamples = []
        lastEmittedText = ""
        lastSpeechAt = nil
        isRecording = true

        transcriptionTask = Task { [weak self] in
            await self?.transcriptionLoop()
        }
    }

    func stopStreaming(sendPending: Bool = true) {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        captureEngine.stop()
        isRecording = false
        isTranscribing = false

        if sendPending {
            let pending = lastEmittedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pending.isEmpty {
                onFinal?(pending)
            }
        }

        accumulatedSamples = []
        lastEmittedText = ""
        lastSpeechAt = nil
        audioLevel = 0

        restoreAudioSession()
        // NOTE: We do NOT unload the model here. WhisperKit stays alive.
    }

    // MARK: - Transcription Loop

    private func transcriptionLoop() async {
        #if canImport(WhisperKit)
        guard let wk = Self.sharedWhisperKit else { return }

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            clipTimestamps: [],
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6
        )

        let minSamples = Int(AudioRingBuffer.sampleRate)

        while !Task.isCancelled && isRecording {
            do {
                try await Task.sleep(for: .seconds(transcriptionInterval))
            } catch { break }
            guard !Task.isCancelled else { break }

            let newSamples = ringBuffer.readAll()
            if !newSamples.isEmpty {
                accumulatedSamples.append(contentsOf: newSamples)
            }

            let energy = energyOf(Array(accumulatedSamples.suffix(1600)))
            if energy > silenceThreshold {
                lastSpeechAt = Date()
            }

            guard accumulatedSamples.count >= minSamples else { continue }

            isTranscribing = true

            do {
                let results = try await wk.transcribe(
                    audioArray: accumulatedSamples,
                    decodeOptions: options
                )

                guard !Task.isCancelled else { break }

                let fullText: String = results
                    .map { result -> String in
                        result.segments.map { $0.text }.joined()
                    }
                    .joined()
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

                if !fullText.isEmpty && fullText != lastEmittedText {
                    lastSpeechAt = Date()
                    lastEmittedText = fullText
                    onPartial?(fullText)
                }

                if let last = lastSpeechAt,
                   Date().timeIntervalSince(last) >= silenceTimeout,
                   !lastEmittedText.isEmpty {
                    let final = lastEmittedText
                    lastEmittedText = ""
                    accumulatedSamples = []
                    lastSpeechAt = nil
                    onFinal?(final)
                }
            } catch {
                logger.error("Transcription error: \(error.localizedDescription)")
            }

            isTranscribing = false
        }
        #endif
    }

    // MARK: - Model Lifecycle

    /// Ensures the shared WhisperKit instance is loaded. Only does work on first call.
    /// Subsequent calls return immediately if model is already loaded.
    private func ensureModelLoaded() async throws {
        #if canImport(WhisperKit)
        // Already loaded — nothing to do
        if Self.sharedWhisperKit != nil { return }

        // Another call is already loading — wait for it
        if Self.isModelLoading {
            while Self.isModelLoading {
                try await Task.sleep(for: .milliseconds(200))
            }
            if Self.sharedWhisperKit != nil { return }
            throw STTError.modelLoadFailed("Concurrent load failed")
        }

        Self.isModelLoading = true
        isLoadingModel = true
        isDownloadingModel = true
        downloadProgress = 0
        statusMessage = "Descargando modelo…"

        do {
            let model = Self.whisperModel
            logger.info("Loading WhisperKit model: \(model) (first time setup)")

            // WhisperKit handles everything internally:
            // - Checks if model already downloaded (cached in Documents/huggingface)
            // - Downloads only if missing
            // - CoreML compilation is cached by the OS after first load
            // - Subsequent inits with same model are fast (~1-2s)
            let wk = try await WhisperKit(
                model: model,
                computeOptions: .init(
                    melCompute: .cpuAndNeuralEngine,
                    audioEncoderCompute: .cpuAndNeuralEngine,
                    textDecoderCompute: .cpuAndNeuralEngine
                ),
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: true
            )

            Self.sharedWhisperKit = wk
            Self.isModelLoading = false
            isLoadingModel = false
            isDownloadingModel = false
            downloadProgress = 1.0
            statusMessage = ""
            logger.info("WhisperKit model loaded successfully")

        } catch {
            Self.isModelLoading = false
            isLoadingModel = false
            isDownloadingModel = false
            downloadProgress = 0
            statusMessage = "Error: \(error.localizedDescription)"
            logger.error("Model load failed: \(error.localizedDescription)")
            throw STTError.modelLoadFailed(error.localizedDescription)
        }
        #else
        throw STTError.modelLoadFailed("WhisperKit not available")
        #endif
    }

    // MARK: - Helpers

    private func energyOf(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSq = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumSq / Float(samples.count))
    }

    private func requestMicPermission() async throws {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted: return
        case .denied: throw STTError.micPermissionDenied
        case .undetermined:
            let ok = await withCheckedContinuation { cont in
                session.requestRecordPermission { cont.resume(returning: $0) }
            }
            if !ok { throw STTError.micPermissionDenied }
        @unknown default:
            throw STTError.micPermissionDenied
        }
    }

    private func restoreAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }
}
