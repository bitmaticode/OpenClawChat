import Foundation
import AVFoundation

/// Lightweight queue-based TTS for streaming responses.
@MainActor
final class SpeechManager: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()

    var isEnabled: Bool = false {
        didSet {
            if !isEnabled {
                stop()
            }
        }
    }

    /// Buffer used to accumulate small deltas and emit utterances at natural boundaries.
    private var pending: String = ""

    /// Guards against enqueuing too aggressively during fast streaming.
    private var lastEnqueueAt: Date = .distantPast

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func stop() {
        pending = ""
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Append newly generated assistant text.
    func append(delta: String, isFinal: Bool) {
        guard isEnabled else { return }
        guard !delta.isEmpty else {
            if isFinal { flush() }
            return
        }

        pending += delta

        // If we have a clear boundary, speak up to it.
        if let idx = boundaryIndex(in: pending) {
            let chunk = String(pending[..<idx])
            pending.removeSubrange(..<idx)
            enqueue(chunk)
        } else {
            // Fallback: speak when it grows too large, but avoid chatter.
            if pending.count >= 220 && Date().timeIntervalSince(lastEnqueueAt) > 0.25 {
                let cut = softCutIndex(in: pending, max: 200) ?? pending.index(pending.startIndex, offsetBy: 200)
                let chunk = String(pending[..<cut])
                pending.removeSubrange(..<cut)
                enqueue(chunk)
            }
        }

        if isFinal {
            flush()
        }
    }

    func flush() {
        guard isEnabled else { return }
        let trimmed = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        if !trimmed.isEmpty {
            enqueue(trimmed)
        }
    }

    private func enqueue(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lastEnqueueAt = Date()

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: preferredLanguage(for: trimmed))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    private func boundaryIndex(in s: String) -> String.Index? {
        // Speak on sentence endings or newlines.
        // Include the boundary char to keep prosody decent.
        let boundaries: [Character] = ["\n", ".", "?", "!"]
        guard let last = s.lastIndex(where: { boundaries.contains($0) }) else { return nil }
        return s.index(after: last)
    }

    private func softCutIndex(in s: String, max: Int) -> String.Index? {
        guard s.count > max else { return nil }
        let limit = s.index(s.startIndex, offsetBy: max)
        // Prefer last space before limit.
        return s[..<limit].lastIndex(of: " ")
    }

    private func preferredLanguage(for text: String) -> String {
        // Cheap heuristic: default to Spanish if we see common chars/words.
        let lower = text.lowercased()
        if lower.contains("¿") || lower.contains("¡") || lower.contains(" que ") || lower.contains("ción") {
            return "es-ES"
        }
        return "en-US"
    }
}
