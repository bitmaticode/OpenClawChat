import Foundation
import AVFoundation
import WhisperKit

@MainActor
final class LocalSTTManager: ObservableObject {
    enum STTError: LocalizedError {
        case micPermissionDenied
        case modelLoadFailed(String)
        case transcriptionFailed

        var errorDescription: String? {
            switch self {
            case .micPermissionDenied: return "Permiso de micrófono denegado"
            case .modelLoadFailed(let detail): return "No pude cargar el modelo Whisper: \(detail)"
            case .transcriptionFailed: return "Falló la transcripción local"
            }
        }
    }

    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isLoadingModel = false
    @Published var modelLoadProgress: Float = 0
    @Published var statusMessage: String = ""

    var onSentence: ((String) -> Void)?
    var onFinal: ((String) -> Void)?

    private var whisperKit: WhisperKit?
    private var realtimeTask: Task<Void, Never>?
    private var lastSpeechAt: Date?
    private var accumulatedText: String = ""
    private var lastEmittedText: String = ""
    private let silenceTimeout: TimeInterval = 1.5
    private let realtimeInterval: TimeInterval = 1.0

    func startStreaming() async throws {
        try await requestMicPermissionIfNeeded()

        if whisperKit == nil {
            isLoadingModel = true
            statusMessage = "Preparando modelo…"

            do {
                let downloadBase = try prepareDownloadBase()
                let repo = "argmaxinc/whisperkit-coreml"
                let modelSupport = await WhisperKit.recommendedRemoteModels(from: repo, downloadBase: downloadBase)
                let modelVariant = modelSupport.default

                try prepareModelDirectories(downloadBase: downloadBase, repo: repo, modelName: modelVariant)

                statusMessage = "Descargando modelo…"
                let config = WhisperKitConfig(
                    model: modelVariant,
                    downloadBase: downloadBase,
                    modelRepo: repo,
                    verbose: false,
                    logLevel: .none,
                    prewarm: true,
                    load: true,
                    download: true,
                    useBackgroundDownloadSession: true
                )
                whisperKit = try await WhisperKit(config)
                isLoadingModel = false
                statusMessage = ""
            } catch {
                isLoadingModel = false
                statusMessage = "Error: \(error.localizedDescription)"
                throw STTError.modelLoadFailed(error.localizedDescription)
            }
        }

        guard let wk = whisperKit else { throw STTError.modelLoadFailed("sin contexto") }

        try configureAudioSession()
        try wk.audioProcessor.startRecordingLive(inputDeviceID: nil, callback: nil)

        isRecording = true
        accumulatedText = ""
        lastEmittedText = ""
        lastSpeechAt = nil

        realtimeTask = Task { [weak self] in
            await self?.realtimeLoop()
        }
    }

    func stopStreaming(sendPending: Bool = true) {
        realtimeTask?.cancel()
        realtimeTask = nil

        whisperKit?.audioProcessor.stopRecording()
        isRecording = false
        isTranscribing = false

        if sendPending {
            let pending = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pending.isEmpty {
                onFinal?(pending)
            }
        }

        accumulatedText = ""
        lastEmittedText = ""
        lastSpeechAt = nil

        restoreAudioSession()
    }

    // MARK: - Realtime loop

    private func realtimeLoop() async {
        guard let wk = whisperKit else { return }

        let decodingOptions = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "es",
            temperature: 0,
            temperatureFallbackCount: 0,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            clipTimestamps: []
        )

        while !Task.isCancelled && isRecording {
            do {
                try await Task.sleep(for: .seconds(realtimeInterval))
            } catch {
                break
            }

            guard !Task.isCancelled else { break }

            let audioSamples = wk.audioProcessor.audioSamples
            guard audioSamples.count > Int(WhisperKit.sampleRate) else { continue }

            isTranscribing = true

            do {
                let result = try await wk.transcribe(
                    audioArray: Array(audioSamples),
                    decodeOptions: decodingOptions
                )

                guard !Task.isCancelled else { break }

                if let segments = result.first?.segments {
                    let fullText = segments.map { $0.text }.joined()
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if !fullText.isEmpty && fullText != lastEmittedText {
                        lastSpeechAt = Date()

                        let newPart: String
                        if fullText.hasPrefix(lastEmittedText) && !lastEmittedText.isEmpty {
                            newPart = String(fullText.dropFirst(lastEmittedText.count))
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        } else {
                            newPart = fullText
                        }

                        lastEmittedText = fullText
                        accumulatedText = fullText

                        if !newPart.isEmpty {
                            onSentence?(newPart)
                        }
                    }
                }

                if let last = lastSpeechAt,
                   Date().timeIntervalSince(last) >= silenceTimeout,
                   !accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let final = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    accumulatedText = ""
                    lastEmittedText = ""
                    lastSpeechAt = nil

                    wk.audioProcessor.purgeAudioSamples(keepingLast: 0)

                    onFinal?(final)
                }
            } catch {
                // Transcription error, continue loop
            }

            isTranscribing = false
        }
    }

    // MARK: - Helpers

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
            if !granted { throw STTError.micPermissionDenied }
        @unknown default:
            throw STTError.micPermissionDenied
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
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

        let modelDirs = [
            "MelSpectrogram.mlmodelc",
            "AudioEncoder.mlmodelc",
            "TextDecoder.mlmodelc",
            "TextDecoderContextPrefill.mlmodelc"
        ]
        for dir in modelDirs {
            let path = modelPath.appendingPathComponent(dir, isDirectory: true)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
    }
}
