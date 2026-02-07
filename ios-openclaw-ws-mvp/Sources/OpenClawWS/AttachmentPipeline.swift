import Foundation
import UniformTypeIdentifiers

public enum ChatAttachmentInput: Sendable {
    case image(data: Data, mimeType: String, fileName: String?)
    case file(url: URL)
}

public struct PreparedMessage: Sendable {
    public let text: String
    public let attachments: [ChatAttachment]

    public init(text: String, attachments: [ChatAttachment]) {
        self.text = text
        self.attachments = attachments
    }
}

public protocol FileAttachmentStrategy: Sendable {
    /// Return extra text to append to the prompt when non-image files are sent.
    func ingest(fileURL: URL) async throws -> String
}

public struct DefaultFileAttachmentStrategy: FileAttachmentStrategy {
    public init() {}

    public func ingest(fileURL: URL) async throws -> String {
        let fileName = fileURL.lastPathComponent
        let type = UTType(filenameExtension: fileURL.pathExtension)

        // Minimal, practical behavior for MVP:
        // - Plain text/markdown/json/csv -> inline text
        // - Others -> send as reference note
        if type?.conforms(to: .plainText) == true ||
            type?.conforms(to: .text) == true ||
            ["md", "markdown", "json", "csv", "txt"].contains(fileURL.pathExtension.lowercased()) {
            let data = try Data(contentsOf: fileURL)
            let text = String(data: data, encoding: .utf8) ?? ""
            let clipped = String(text.prefix(12_000))
            return "\n\n[Archivo: \(fileName)]\n\(clipped)"
        }

        return "\n\n[Archivo adjunto no-imagen: \(fileName)]\nNo puedo enviarlo binario por WS chat.send todavía; por favor úsalo como referencia y pídeme análisis por texto o enlace."
    }
}

public struct AttachmentPipeline: Sendable {
    private let fileStrategy: FileAttachmentStrategy
    private let maxImageBytes: Int

    public init(fileStrategy: FileAttachmentStrategy = DefaultFileAttachmentStrategy(), maxImageBytes: Int = 5_000_000) {
        self.fileStrategy = fileStrategy
        self.maxImageBytes = maxImageBytes
    }

    public func prepare(text: String, inputs: [ChatAttachmentInput]) async throws -> PreparedMessage {
        var mergedText = text
        var imageAttachments: [ChatAttachment] = []

        for item in inputs {
            switch item {
            case .image(let data, let mimeType, let fileName):
                let encoded = try encodeImageBase64(data: data)
                imageAttachments.append(.init(mimeType: mimeType, fileName: fileName, content: encoded))

            case .file(let url):
                let addition = try await fileStrategy.ingest(fileURL: url)
                mergedText.append(addition)
            }
        }

        return PreparedMessage(text: mergedText, attachments: imageAttachments)
    }

    private func encodeImageBase64(data: Data) throws -> String {
        guard !data.isEmpty else { throw PipelineError.emptyImage }
        guard data.count <= maxImageBytes else {
            throw PipelineError.imageTooLarge(current: data.count, max: maxImageBytes)
        }
        return data.base64EncodedString()
    }

    public enum PipelineError: Error, LocalizedError {
        case emptyImage
        case imageTooLarge(current: Int, max: Int)

        public var errorDescription: String? {
            switch self {
            case .emptyImage: return "La imagen está vacía"
            case .imageTooLarge(let current, let max):
                return "Imagen demasiado grande: \(current) bytes (máximo \(max))"
            }
        }
    }
}
