import SwiftUI

/// A device glyph in a soft rounded tile, like in Settings.
struct DeviceTile: View {
    let kind: DeviceKind
    var size: CGFloat = 40
    var tint: Color = .accentColor

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: kind.symbolName)
                    .font(.system(size: size * 0.48, weight: .medium))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// A small dot that gently pulses, used for "live" and "visible" states.
struct PulsingDot: View {
    var color: Color = .green
    @State private var animate = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: 16, height: 16)
                .scaleEffect(animate ? 1.2 : 0.6)
                .opacity(animate ? 0 : 1)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .frame(width: 16, height: 16)
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
        .accessibilityHidden(true)
    }
}

/// Side-to-side shake for a wrong code.
struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(animatableData * .pi * 4), y: 0))
    }
}

/// A short message that slides in from the top.
struct ToastView: View {
    let toast: AppModel.Toast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
            Text(toast.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
    }
}

/// The big pairing code, Apple TV style.
struct CodeDigitsView: View {
    let code: String

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(code.enumerated()), id: \.offset) { index, digit in
                Text(String(digit))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 46, height: 64)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                if index == 2 {
                    Spacer().frame(width: 8)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pairing code \(code.map(String.init).joined(separator: " "))")
    }
}

extension View {
    /// Keeps lists readable on the wide iPad screen.
    func readableWidth(_ maxWidth: CGFloat = 680) -> some View {
        modifier(ReadableWidth(maxWidth: maxWidth))
    }
}

private struct ReadableWidth: ViewModifier {
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            content
                .contentMargins(.horizontal, max(0, (proxy.size.width - maxWidth) / 2), for: .scrollContent)
        }
    }
}
