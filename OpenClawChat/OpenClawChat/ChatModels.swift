import Foundation

enum ChatSender: String, Codable, Sendable {
    case user
    case assistant
    case system
}

enum ChatItemStyle: String, Codable, Sendable {
    case normal
    case status
    case error
}

struct ChatAttachmentLocal: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case image
    }

    let kind: Kind
    /// Absolute file path inside the app sandbox.
    let path: String
    let mimeType: String
    let fileName: String?
}

struct ChatItem: Identifiable, Codable, Sendable {
    var id: UUID
    let sender: ChatSender
    var text: String
    let style: ChatItemStyle
    let createdAt: Date

    var attachment: ChatAttachmentLocal?

    init(
        id: UUID = UUID(),
        sender: ChatSender,
        text: String,
        style: ChatItemStyle = .normal,
        createdAt: Date = Date(),
        attachment: ChatAttachmentLocal? = nil
    ) {
        self.id = id
        self.sender = sender
        self.text = text
        self.style = style
        self.createdAt = createdAt
        self.attachment = attachment
    }
}
