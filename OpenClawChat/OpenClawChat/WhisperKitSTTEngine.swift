//
//  WhisperKitSTTEngine.swift
//  OpenClawChat
//
//  Non-UI actor that loads WhisperKit and runs transcriptions off the MainActor.
//  This mirrors LAIA's WhisperSTTProvider actor pattern.
//

import Foundation
import os

#if canImport(WhisperKit)
import WhisperKit
#endif

actor WhisperKitSTTEngine {
    static let shared = WhisperKitSTTEngine()

    private let logger = Logger(subsystem: "ai.openclaw.chat", category: "WhisperKitSTTEngine")

    #if canImport(WhisperKit)
    private var whisperKit: WhisperKit?
    private var loadedModel: String?
    #endif

    private static let modelRepo = "argmaxinc/whisperkit-coreml"

    private func modelFolderDefaultsKey(for model: String) -> String {
        "openclaw.stt.modelFolder.\(model)"
    }

    func downloadBase() throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = root.appendingPathComponent("huggingface", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func isValidModelFolder(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        let required = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
        for name in required {
            let mlmodelc = url.appendingPathComponent("\(name).mlmodelc")
            let mlpackage = url.appendingPathComponent("\(name).mlpackage")
            if !fm.fileExists(atPath: mlmodelc.path) && !fm.fileExists(atPath: mlpackage.path) {
                return false
            }
        }
        return true
    }

    /// Ensure WhisperKit is loaded for a given model. Heavy work happens on this actor (not MainActor).
    func ensureLoaded(
        model: String,
        progress: (@Sendable (Double) -> Void)? = nil,
        status: (@Sendable (String) -> Void)? = nil
    ) async throws {
        #if canImport(WhisperKit)
        if let wk = whisperKit, loadedModel == model {
            _ = wk
            return
        }

        status?("Preparando modelo…")
        let start = Date()

        let base = try downloadBase()
        let key = modelFolderDefaultsKey(for: model)

        var folderURL: URL?
        if let cachedPath = UserDefaults.standard.string(forKey: key) {
            let url = URL(fileURLWithPath: cachedPath)
            if isValidModelFolder(url) {
                folderURL = url
                logger.info("Using cached model folder: \(url.path)")
            } else {
                logger.warning("Cached model folder invalid, removing: \(url.path)")
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        if folderURL == nil {
            status?("Descargando modelo…")
            progress?(0)
            let modelFolder = try await WhisperKit.download(
                variant: model,
                downloadBase: base,
                useBackgroundSession: false,
                from: Self.modelRepo
            ) { p in
                progress?(p.fractionCompleted)
            }
            folderURL = modelFolder
            UserDefaults.standard.set(modelFolder.path, forKey: key)
            progress?(1)
            logger.info("Download complete: \(modelFolder.path)")
        }

        guard let folder = folderURL else {
            throw NSError(domain: "WhisperKitSTTEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model folder unavailable"])
        }

        status?("Cargando modelo…")

        // NOTE: prewarm=false to avoid long first-time specialization loops.
        // The first transcription will still warm caches.
        let wk = try await WhisperKit(
            modelFolder: folder.path,
            computeOptions: .init(
                melCompute: .cpuAndNeuralEngine,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            ),
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )

        whisperKit = wk
        loadedModel = model

        let elapsed = Date().timeIntervalSince(start)
        logger.info("WhisperKit loaded for \(model) in \(String(format: "%.2f", elapsed))s")
        #else
        throw NSError(domain: "WhisperKitSTTEngine", code: 2, userInfo: [NSLocalizedDescriptionKey: "WhisperKit not available"])
        #endif
    }

    func transcribe(audioSamples: [Float], language: String) async throws -> String {
        #if canImport(WhisperKit)
        guard let wk = whisperKit else {
            throw NSError(domain: "WhisperKitSTTEngine", code: 3, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperatureFallbackCount: 3,
            usePrefillPrompt: false,
            usePrefillCache: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            clipTimestamps: [],
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6
        )

        let results = try await wk.transcribe(audioArray: audioSamples, decodeOptions: options)
        let transcription = results
            .compactMap { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return transcription
        #else
        throw NSError(domain: "WhisperKitSTTEngine", code: 4, userInfo: [NSLocalizedDescriptionKey: "WhisperKit not available"])
        #endif
    }
}
