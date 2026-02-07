import Foundation

enum ChatSender: String, Sendable {
    case user
    case assistant
    case system
}

enum ChatItemStyle: Sendable {
    case normal
    case status
    case error
}

struct ChatItem: Identifiable, Sendable {
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
