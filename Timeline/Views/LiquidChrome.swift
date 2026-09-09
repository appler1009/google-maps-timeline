import SwiftUI

extension View {
    /// Small floating chip over the map (back, title, day stepper).
    func mapGlassChip(cornerRadius: CGFloat = 10) -> some View {
        modifier(MapGlassChipModifier(cornerRadius: cornerRadius))
    }

    /// Larger floating surface (day/place legend).
    func mapGlassCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(MapGlassCardModifier(cornerRadius: cornerRadius))
    }

    func glassCluster(spacing: CGFloat = 8) -> some View {
        modifier(GlassClusterModifier(spacing: spacing))
    }

    @ViewBuilder
    func timelineBackgroundExtension() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            backgroundExtensionEffect()
        } else {
            self
        }
    }

    @ViewBuilder
    func timelineGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

private struct GlassClusterModifier: ViewModifier {
    var spacing: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

private struct MapGlassChipModifier: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, macOS 26.0, *) {
            #if os(iOS)
            content.glassEffect(.clear.interactive(), in: shape)
            #else
            content.glassEffect(.clear, in: shape)
            #endif
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Palette.parchment.opacity(0.12), lineWidth: 1))
        }
    }
}

private struct MapGlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Palette.parchment.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        }
    }
}
