import SwiftUI

struct ChatBubbleView: View {
    let item: ChatItem
    let isStreaming: Bool

    init(item: ChatItem, isStreaming: Bool = false) {
        self.item = item
        self.isStreaming = isStreaming
    }

    private var isUser: Bool { item.sender == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if isUser { Spacer(minLength: 40) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                messageBody
                    .font(.body)
                    .foregroundStyle(foreground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(bubble)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contextMenu {
                        Button("Copiar") {
                            UIPasteboard.general.string = item.text
                        }
                        ShareLink(item: item.text) {
                            Text("Compartir")
                        }
                    }

                // Keep bubbles clean; style/color already conveys status.
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)

            if !isUser { Spacer(minLength: 40) }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var messageBody: some View {
        if let attachment = item.attachment, attachment.kind == .image {
            VStack(alignment: .leading, spacing: 8) {
                if let uiImage = UIImage(contentsOfFile: attachment.path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 260, maxHeight: 260)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Text("(imagen)")
                }

                if !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    markdownText(item.text)
                }
            }
        } else {
            if isStreaming {
                // Avoid expensive markdown parsing while deltas are coming in.
                Text(item.text + "▍")
            } else {
                markdownText(item.text)
            }
        }
    }

    @ViewBuilder
    private func markdownText(_ raw: String) -> some View {
        if let md = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        ) {
            Text(md)
        } else {
            Text(raw)
        }
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

    // label removed
}
