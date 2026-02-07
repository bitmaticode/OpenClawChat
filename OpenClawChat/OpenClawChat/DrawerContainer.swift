import SwiftUI

struct DrawerContainer<Content: View>: View {
    @Binding var isOpen: Bool
    let menu: AnyView
    let content: Content

    init(isOpen: Binding<Bool>, menu: AnyView, @ViewBuilder content: () -> Content) {
        self._isOpen = isOpen
        self.menu = menu
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .leading) {
            content
                .disabled(isOpen)

            if isOpen {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { isOpen = false } }
                    .transition(.opacity)
            }

            menu
                .frame(width: 310)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(radius: 30)
                .offset(x: isOpen ? 12 : -340)
                .padding(.vertical, 10)
                .padding(.leading, 10)
                .animation(.spring(response: 0.28, dampingFraction: 0.9), value: isOpen)
        }
    }
}
