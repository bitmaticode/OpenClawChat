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

struct ChatItem: Identifiable, Codable, Sendable {
    var id: UUID
    let sender: ChatSender
    var text: String
    let style: ChatItemStyle
    let createdAt: Date

    init(id: UUID = UUID(), sender: ChatSender, text: String, style: ChatItemStyle = .normal, createdAt: Date = Date()) {
        self.id = id
        self.sender = sender
        self.text = text
        self.style = style
        self.createdAt = createdAt
    }
}
