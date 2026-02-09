//
//  LocalSTTManager.swift
//  OpenClawChat
//
//  On-device Speech-to-Text using WhisperKit (CoreML + Apple Neural Engine).
//
//  Architecture (following LAIA's pattern):
//  1. User taps mic → start AVAudioEngine capture
//  2. Audio accumulates in ring buffer, energy monitored for VAD
//  3. Silence detected (or user taps mic again) → stop capture
//  4. Transcribe complete audio in ONE shot (like LAIA's WhisperSTTProvider)
//  5. Result goes to draft → auto-send
//
//  Key: NO continuous polling/re-transcription. Single transcription per utterance.
//

import Foundation
import AVFoundation
import os

#if canImport(WhisperKit)
import WhisperKit
#endif

// MARK: - Audio Ring Buffer

final class AudioRingBuffer: @unchecked Sendable {
    static let sampleRate: Double = 16000
    static let capacity: Int = Int(sampleRate * 30) // 30 seconds max

    private let storage: UnsafeMutableBufferPointer<Float>
    private var writeIdx = 0
    private var count_ = 0
    private let lock = OSAllocatedUnfairLock()

    var count: Int { lock.withLock { count_ } }

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
                if count_ < Self.capacity { count_ += 1 }
            }
        }
    }

    /// Get ALL accumulated samples in order (non-destructive).
    func getAll() -> [Float] {
        lock.withLock {
            guard count_ > 0 else { return [] }
            var out = [Float](repeating: 0, count: count_)
            let startIdx = (writeIdx - count_ + Self.capacity) % Self.capacity
            for i in 0..<count_ {
                out[i] = storage[(startIdx + i) % Self.capacity]
            }
            return out
        }
    }

    func clear() {
        lock.withLock {
            writeIdx = 0
            count_ = 0
        }
    }
}

// MARK: - Audio Capture Engine

final class AudioCaptureEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let ringBuffer: AudioRingBuffer
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private let logger = Logger(subsystem: "ai.openclaw.chat", category: "AudioCapture")
    private var _isCapturing = false

    var isCapturing: Bool { _isCapturing }

    /// Called on audio thread with RMS energy level.
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

        // RMS energy
        var rms: Float = 0
        for i in 0..<length { rms += channelData[i] * channelData[i] }
        rms = sqrt(rms / Float(length))
        onAudioLevel?(rms)
    }
}

// MARK: - LocalSTTManager

@MainActor
final class LocalSTTManager: ObservableObject {

    // MARK: - Errors

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

    // MARK: - Published state

    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isLoadingModel = false
    @Published var isDownloadingModel = false
    @Published var downloadProgress: Double = 0
    @Published var statusMessage = ""
    @Published var audioLevel: Float = 0

    // MARK: - Callbacks

    /// Called with final transcription text (ready to send).
    var onFinal: ((String) -> Void)?

    // MARK: - Configuration

    /// Model to use. Match LAIA: large-v3 but we use medium for faster load.
    static let whisperModel = "openai_whisper-large-v3-v20240930_turbo"

    private let silenceThreshold: Float = 0.01
    private let silenceTimeout: TimeInterval = 1.5
    private let maxRecordingDuration: TimeInterval = 30.0
    private let language = "es"

    // MARK: - Internal

    private let ringBuffer = AudioRingBuffer()
    private lazy var captureEngine = AudioCaptureEngine(ringBuffer: ringBuffer)
    private let logger = Logger(subsystem: "ai.openclaw.chat", category: "STT")

    // WhisperKit lifecycle is managed by WhisperKitSTTEngine (actor)

    private var silenceMonitorTask: Task<Void, Never>?
    private var lastVoiceActivityAt: Date?

    // MARK: - Public API

    /// Start recording. Call ensureModelLoaded first or it will load on demand.
    func startStreaming() async throws {
        try await requestMicPermission()
        try await ensureModelLoaded()

        try captureEngine.setup()

        captureEngine.onAudioLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.audioLevel = level
            }
        }

        ringBuffer.clear()
        lastVoiceActivityAt = Date()
        isRecording = true

        try captureEngine.start()
        startSilenceMonitor()
    }

    /// Stop recording and transcribe the accumulated audio.
    func stopStreaming(sendPending: Bool = true) {
        silenceMonitorTask?.cancel()
        silenceMonitorTask = nil
        captureEngine.stop()

        let wasRecording = isRecording
        isRecording = false
        audioLevel = 0

        if sendPending && wasRecording {
            let samples = ringBuffer.getAll()
            if samples.count > Int(AudioRingBuffer.sampleRate * 0.3) { // at least 0.3s of audio
                transcribeAndSend(samples)
            }
        }

        restoreAudioSession()
    }

    // MARK: - Silence Monitor

    /// Monitors audio energy. When silence persists for `silenceTimeout`, stops recording and transcribes.
    private func startSilenceMonitor() {
        silenceMonitorTask = Task { [weak self] in
            guard let self = self else { return }

            while !Task.isCancelled && self.isRecording {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch { break }

                let level = self.audioLevel

                if level > self.silenceThreshold {
                    self.lastVoiceActivityAt = Date()
                }

                // Auto-stop after silence timeout
                if let lastVoice = self.lastVoiceActivityAt,
                   Date().timeIntervalSince(lastVoice) >= self.silenceTimeout {
                    self.logger.info("Silence detected — stopping recording")
                    self.stopStreaming(sendPending: true)
                    break
                }

                // Safety: max recording duration
                if let lastVoice = self.lastVoiceActivityAt,
                   Date().timeIntervalSince(lastVoice) >= self.maxRecordingDuration {
                    self.logger.info("Max recording duration — stopping")
                    self.stopStreaming(sendPending: true)
                    break
                }
            }
        }
    }

    // MARK: - Transcription (single shot, like LAIA)

    private func transcribeAndSend(_ audioSamples: [Float]) {
        Task { [weak self] in
            guard let self else { return }
            isTranscribing = true
            defer { isTranscribing = false }

            do {
                // Run transcription off the MainActor via WhisperKitSTTEngine (actor), like LAIA.
                let text = try await WhisperKitSTTEngine.shared.transcribe(
                    audioSamples: audioSamples,
                    language: language
                )

                logger.info("Transcribed: \"\(text.prefix(80))\"")
                let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    onFinal?(trimmed)
                }
            } catch {
                logger.error("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Model Lifecycle

    /// Ensure the model is ready. Heavy work runs in WhisperKitSTTEngine actor (not MainActor),
    /// mirroring LAIA's `WhisperSTTProvider` actor approach.
    private func ensureModelLoaded() async throws {
        isLoadingModel = true
        isDownloadingModel = false
        downloadProgress = 0
        statusMessage = "Preparando modelo…"

        do {
            try await WhisperKitSTTEngine.shared.ensureLoaded(
                model: Self.whisperModel,
                progress: { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        self?.downloadProgress = fraction
                    }
                },
                status: { [weak self] text in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.statusMessage = text
                        self.isDownloadingModel = text.lowercased().contains("descargando")
                    }
                }
            )

            isLoadingModel = false
            isDownloadingModel = false
            statusMessage = ""
        } catch {
            isLoadingModel = false
            isDownloadingModel = false
            statusMessage = "Error: \(error.localizedDescription)"
            throw STTError.modelLoadFailed(error.localizedDescription)
        }
    }


    // MARK: - Helpers

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
