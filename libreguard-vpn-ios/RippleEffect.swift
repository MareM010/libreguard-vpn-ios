import SwiftUI

/// A lightweight touch ripple that works with both SwiftUI controls and custom views.
/// The gesture is simultaneous so it never takes ownership of the control's action.
struct RippleEffectModifier: ViewModifier {
    let tint: Color
    let shape: AnyShape

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ripples: [Ripple] = []

    func body(content: Content) -> some View {
        content
            .contentShape(shape)
            .overlay {
                GeometryReader { proxy in
                    ZStack {
                        ForEach(ripples) { ripple in
                            Circle()
                                .fill(tint.opacity(0.18))
                                .overlay {
                                    Circle()
                                        .stroke(tint.opacity(0.42), lineWidth: 1.5)
                                }
                                .frame(width: 72, height: 72)
                                .scaleEffect(
                                    ripple.isExpanded
                                        ? max(1, max(proxy.size.width, proxy.size.height) / 36)
                                        : 0.01
                                )
                                .opacity(ripple.isExpanded ? 0 : 1)
                                .position(ripple.location)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }
            }
            .clipShape(shape)
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        triggerRipple(at: value.location)
                    },
                including: .all
            )
    }

    private func triggerRipple(at location: CGPoint) {
        let ripple = Ripple(location: location)
        ripples.append(ripple)

        withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.55)) {
            guard let index = ripples.firstIndex(where: { $0.id == ripple.id }) else { return }
            ripples[index].isExpanded = true
        }

        let removalDelay = reduceMotion ? 0.22 : 0.58
        DispatchQueue.main.asyncAfter(deadline: .now() + removalDelay) {
            withAnimation(.easeOut(duration: 0.16)) {
                ripples.removeAll { $0.id == ripple.id }
            }
        }
    }

    private struct Ripple: Identifiable {
        let id = UUID()
        let location: CGPoint
        var isExpanded = false
    }
}

extension View {
    func rippleEffect(tint: Color = .white, shape: AnyShape = AnyShape(Rectangle())) -> some View {
        modifier(RippleEffectModifier(tint: tint, shape: shape))
    }

    func rippleEffect<S: Shape>(tint: Color = .white, shape: S) -> some View {
        modifier(RippleEffectModifier(tint: tint, shape: AnyShape(shape)))
    }
}
