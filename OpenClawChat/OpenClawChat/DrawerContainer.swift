import SwiftUI

struct DrawerContainer<Content: View>: View {
    @Binding var isOpen: Bool
    let menu: AnyView
    let content: Content

    private let menuWidth: CGFloat = 300
    @State private var dragOffset: CGFloat = 0

    init(isOpen: Binding<Bool>, menu: AnyView, @ViewBuilder content: () -> Content) {
        self._isOpen = isOpen
        self.menu = menu
        self.content = content()
    }

    // MARK: - Computed geometry

    private var menuX: CGFloat {
        let base: CGFloat = isOpen ? 0 : -menuWidth
        return max(-menuWidth, min(0, base + dragOffset))
    }

    /// 0 = fully closed, 1 = fully open
    private var progress: CGFloat {
        (menuX + menuWidth) / menuWidth
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .leading) {
            content
                .disabled(isOpen)

            Color.black.opacity(0.4 * progress)
                .ignoresSafeArea()
                .allowsHitTesting(isOpen && dragOffset == 0)
                .onTapGesture {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        isOpen = false
                    }
                }

            menu
                .frame(width: menuWidth)
                .frame(maxHeight: .infinity)
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 16,
                        topTrailingRadius: 16,
                        style: .continuous
                    )
                    .fill(Color(uiColor: .systemBackground))
                    .ignoresSafeArea(.container, edges: .vertical)
                )
                .shadow(color: .black.opacity(0.12 * progress), radius: 15, x: 5)
                .offset(x: menuX)
        }
        .gesture(dragGesture)
    }

    // MARK: - Drag gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .global)
            .onChanged { value in
                let t = value.translation.width
                if isOpen {
                    dragOffset = min(0, t)
                } else if value.startLocation.x < 35 {
                    dragOffset = max(0, t)
                }
            }
            .onEnded { value in
                let velocity = value.predictedEndTranslation.width
                let shouldOpen: Bool

                if isOpen {
                    shouldOpen = !(dragOffset < -menuWidth * 0.3 || velocity < -200)
                } else if value.startLocation.x < 35 {
                    shouldOpen = dragOffset > menuWidth * 0.3 || velocity > 200
                } else {
                    shouldOpen = isOpen
                }

                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    isOpen = shouldOpen
                    dragOffset = 0
                }
            }
    }
}
