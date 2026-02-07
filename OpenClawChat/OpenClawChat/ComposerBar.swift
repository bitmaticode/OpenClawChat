import SwiftUI

struct ComposerBar: View {
    @Binding var text: String
    let isEnabled: Bool
    let onSend: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            TextField("Escribe…", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .focused($focused)

            Button {
                onSend()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(12)
                    .background(isEnabled ? Color.accentColor : Color.gray.opacity(0.3))
                    .foregroundStyle(isEnabled ? .white : .secondary)
                    .clipShape(Circle())
            }
            .disabled(!isEnabled)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }
}
