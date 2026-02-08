import Foundation

/// Simple on-device persistence for chat threads.
/// Stores one JSON file per sessionKey under Application Support.
enum ChatStore {
    private static func baseDir() throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("openclawchat", isDirectory: true)
            .appendingPathComponent("threads", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func safeFilename(for sessionKey: String) -> String {
        // Keep it filesystem-friendly and deterministic.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = sessionKey.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(cleaned) + ".json"
    }

    static func load(sessionKey: String) -> [ChatItem]? {
        do {
            let dir = try baseDir()
            let url = dir.appendingPathComponent(safeFilename(for: sessionKey))
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([ChatItem].self, from: data)
        } catch {
            return nil
        }
    }

    static func save(sessionKey: String, items: [ChatItem]) {
        do {
            let dir = try baseDir()
            let url = dir.appendingPathComponent(safeFilename(for: sessionKey))
            let data = try JSONEncoder().encode(items)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Best-effort persistence.
        }
    }
}
