import Foundation

enum AttachmentStore {
    private static func baseDir() throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("openclawchat", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func saveImageJPEG(data: Data, fileName: String? = nil) throws -> ChatAttachmentLocal {
        let dir = try baseDir()
        let base = (fileName?.isEmpty == false ? fileName! : UUID().uuidString)
        let sanitized = base
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")

        let finalName = sanitized.lowercased().hasSuffix(".jpg") || sanitized.lowercased().hasSuffix(".jpeg")
            ? sanitized
            : sanitized + ".jpg"

        let url = dir.appendingPathComponent(finalName)
        try data.write(to: url, options: [.atomic])

        return ChatAttachmentLocal(
            kind: .image,
            path: url.path,
            mimeType: "image/jpeg",
            fileName: finalName
        )
    }
}
