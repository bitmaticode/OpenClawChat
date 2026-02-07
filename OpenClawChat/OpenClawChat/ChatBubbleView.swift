import SwiftUI

struct ChatBubbleView: View {
    let item: ChatItem

    private var isUser: Bool { item.sender == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if !isUser {
                avatar
            } else {
                Spacer(minLength: 44)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                Text(item.text)
                    .font(.body)
                    .foregroundStyle(foreground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(bubble)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                if item.style != .normal {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)

            if isUser {
                avatar
            } else {
                Spacer(minLength: 44)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var avatar: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Text(emoji)
                .font(.system(size: 16))
        }
        .frame(width: 28, height: 28)
    }

    private var bubble: some ShapeStyle {
        switch item.style {
        case .normal:
            return isUser ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(Color.secondary.opacity(0.10))
        case .status:
            return AnyShapeStyle(Color.blue.opacity(0.12))
        case .error:
            return AnyShapeStyle(Color.red.opacity(0.14))
        }
    }

    private var foreground: Color {
        switch item.style {
        case .normal:
            return .primary
        case .status:
            return .primary
        case .error:
            return .red
        }
    }

    private var emoji: String {
        switch item.sender {
        case .user: return "🧑"
        case .assistant: return "🤖"
        case .system: return "ℹ️"
        }
    }

    private var label: String {
        switch item.style {
        case .normal: return ""
        case .status: return "estado"
        case .error: return "error"
        }
    }
}
