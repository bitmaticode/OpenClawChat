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
    let id: UUID = UUID()
    let sender: ChatSender
    let text: String
    let style: ChatItemStyle
    let createdAt: Date

    init(sender: ChatSender, text: String, style: ChatItemStyle = .normal, createdAt: Date = Date()) {
        self.sender = sender
        self.text = text
        self.style = style
        self.createdAt = createdAt
    }
}
