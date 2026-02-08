//
//  LocalSTTManager.swift
//  OpenClawChat
//
//  On-device Speech-to-Text using WhisperKit (CoreML + Apple Neural Engine).
//  Inspired by LAIA's architecture: own AVAudioEngine capture → ring buffer → WhisperKit transcribe.
//

import Foundation
import AVFoundation
import os

#if canImport(WhisperKit)
import WhisperKit
#endif

// MARK: - Audio Ring Buffer

/// Thread-safe ring buffer for real-time 16kHz mono audio samples.
/// Uses OSAllocatedUnfairLock for non-blocking access from the audio render thread.
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

    /// Write from audio callback – minimal overhead, real-time safe.
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

    /// Read all available samples in order (consumes them).
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

    /// Peek at the last N samples without consuming.
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

    /// RMS energy of the most recent `n` samples.
    func recentEnergy(_ n: Int = 1600) -> Float {
        let samples = peekLast(n)
        guard !samples.isEmpty else { return 0 }
        let sumSq = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumSq / Float(samples.count))
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

    /// Callback for audio level (RMS) updates – called on audio thread.
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
            logger.info("Audio converter: \(inputFormat.sampleRate)Hz → \(self.targetFormat.sampleRate)Hz")
        }
    }

    func start() throws {
        guard !_isCapturing else { return }
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        let bufferSize: AVAudioFrameCount = 1600 // 100ms at 16kHz

        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) {
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

        // RMS for level callback
        var rms: Float = 0
        for i in 0..<length { rms += channelData[i] * channelData[i] }
        rms = sqrt(rms / Float(length))
        onAudioLevel?(rms)
    }

    /// Set up audio interruption / route change handling.
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
    @Published var downloadProgress: Double = 0   // 0.0–1.0
    @Published var statusMessage = ""
    @Published var audioLevel: Float = 0

    // MARK: Callbacks

    /// Partial text as it arrives (for live preview in composer).
    var onPartial: ((String) -> Void)?
    /// Final transcription after silence detected – auto-sends.
    var onFinal: ((String) -> Void)?

    // MARK: Configuration

    private let silenceThreshold: Float = 0.008
    private let silenceTimeout: TimeInterval = 1.5
    private let transcriptionInterval: TimeInterval = 1.0
    private let idleModelTimeout: TimeInterval = 60.0
    private let language = "es"

    // MARK: Internal components

    private let ringBuffer = AudioRingBuffer()
    private lazy var captureEngine = AudioCaptureEngine(ringBuffer: ringBuffer)
    private let logger = Logger(subsystem: "ai.openclaw.chat", category: "STT")

    #if canImport(WhisperKit)
    private var whisperKit: WhisperKit?
    #endif

    private var transcriptionTask: Task<Void, Never>?
    private var idleTimer: Task<Void, Never>?
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

        resetIdleTimer()
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
        resetIdleTimer()
    }

    /// Manually unload model to free memory.
    func unloadModel() {
        #if canImport(WhisperKit)
        whisperKit = nil
        #endif
        idleTimer?.cancel()
        idleTimer = nil
        logger.info("WhisperKit model unloaded")
    }

    // MARK: - Transcription Loop

    private func transcriptionLoop() async {
        #if canImport(WhisperKit)
        guard let wk = whisperKit else { return }

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

        let minSamples = Int(AudioRingBuffer.sampleRate) // 1 second minimum

        while !Task.isCancelled && isRecording {
            do {
                try await Task.sleep(for: .seconds(transcriptionInterval))
            } catch { break }
            guard !Task.isCancelled else { break }

            // Drain ring buffer into accumulated samples
            let newSamples = ringBuffer.readAll()
            if !newSamples.isEmpty {
                accumulatedSamples.append(contentsOf: newSamples)
            }

            // Check energy for VAD
            let energy = energyOf(Array(accumulatedSamples.suffix(1600)))
            let hasSpeech = energy > silenceThreshold

            if hasSpeech {
                lastSpeechAt = Date()
            }

            // Need minimum audio to transcribe
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

                // Silence timeout → finalize and reset
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

    private let modelVariant = "openai_whisper-large-v3-v20240930_turbo"
    private let modelRepo = "argmaxinc/whisperkit-coreml"

    private func ensureModelLoaded() async throws {
        #if canImport(WhisperKit)
        guard whisperKit == nil else { return }

        isLoadingModel = true
        statusMessage = "Preparando…"

        do {
            let downloadBase = try prepareDownloadBase()

            try prepareModelDirectories(downloadBase: downloadBase, repo: modelRepo, modelName: modelVariant)
            cleanEmptyModelDirs(downloadBase: downloadBase, repo: modelRepo, modelName: modelVariant)

            // Step 1: Download model with progress tracking
            logger.info("Downloading WhisperKit model: \(self.modelVariant)")
            isDownloadingModel = true
            downloadProgress = 0

            let modelFolder = try await WhisperKit.download(
                variant: modelVariant,
                downloadBase: downloadBase,
                useBackgroundSession: false,
                from: modelRepo
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let fraction = progress.fractionCompleted
                    self.downloadProgress = fraction
                    let pct = Int(fraction * 100)
                    self.statusMessage = "Descargando modelo… \(pct)%"
                }
            }

            isDownloadingModel = false
            downloadProgress = 1.0
            statusMessage = "Compilando para Neural Engine…\n(primera vez tarda ~2 min)"
            logger.info("Model downloaded to: \(modelFolder.path)")

            // Step 2: Init WhisperKit with the downloaded folder (no download needed)
            // prewarm: false → skip double compilation, model warms on first transcription
            let config = WhisperKitConfig(
                modelFolder: modelFolder.path,
                computeOptions: .init(
                    melCompute: .cpuAndNeuralEngine,
                    audioEncoderCompute: .cpuAndNeuralEngine,
                    textDecoderCompute: .cpuAndNeuralEngine
                ),
                verbose: true,
                logLevel: .debug,
                prewarm: false,
                load: true,
                download: false
            )

            whisperKit = try await WhisperKit(config)
            isLoadingModel = false
            isDownloadingModel = false
            statusMessage = ""
            logger.info("WhisperKit model loaded successfully")

        } catch {
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

    private func resetIdleTimer() {
        idleTimer?.cancel()
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.idleModelTimeout ?? 60))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self = self, !self.isRecording else { return }
                self.logger.info("Idle timeout – unloading WhisperKit model")
                self.unloadModel()
            }
        }
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

    private func prepareDownloadBase() throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = root.appendingPathComponent("huggingface", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func prepareModelDirectories(downloadBase: URL, repo: String, modelName: String) throws {
        let repoPath = downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
        let modelPath = repoPath.appendingPathComponent(modelName, isDirectory: true)
        try FileManager.default.createDirectory(at: modelPath, withIntermediateDirectories: true)
        // NOTE: Don't pre-create .mlmodelc subdirectories — HubApi's Downloader
        // creates them automatically via moveDownloadedFile(). Pre-creating empty
        // dirs causes WhisperKit to detect them as "existing" optional models
        // (e.g. TextDecoderContextPrefill) and fail to load the empty bundle.
    }

    /// Remove stale empty .mlmodelc directories that could confuse WhisperKit.
    private func cleanEmptyModelDirs(downloadBase: URL, repo: String, modelName: String) {
        let modelPath = downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent(modelName, isDirectory: true)
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: modelPath.path) else { return }
        for item in contents where item.hasSuffix(".mlmodelc") {
            let dir = modelPath.appendingPathComponent(item)
            // If the .mlmodelc dir is empty or has no actual model files, remove it
            let subItems = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            if subItems.isEmpty {
                try? fm.removeItem(at: dir)
                logger.info("Removed empty model dir: \(item)")
            }
        }
    }
}
