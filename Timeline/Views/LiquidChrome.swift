import SwiftUI

/// Pin labels sit in an MKAnnotation hosting view, so Liquid Glass cannot sample
/// the map underneath. Use alpha fills so the tiles actually show through.
private struct MapPinLabelChipModifier: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(Palette.ink.opacity(0.42))
                    shape.fill(
                        LinearGradient(
                            colors: [
                                Palette.parchment.opacity(0.14),
                                Palette.ink.opacity(0.08),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .overlay(shape.stroke(Palette.parchment.opacity(0.38), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
    }
}

extension View {
    /// Small floating chip over the map (back, title, day stepper).
    func mapGlassChip(cornerRadius: CGFloat = 10) -> some View {
        modifier(MapGlassChipModifier(cornerRadius: cornerRadius))
    }

    /// Denser chip for map pin name labels — readable over satellite tiles.
    func mapPinLabelChip(cornerRadius: CGFloat = 12) -> some View {
        modifier(MapPinLabelChipModifier(cornerRadius: cornerRadius))
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

/// Shared map pin + optional name chip, sized for MapKit annotation hosting.
struct MapVisitPinChrome: View {
    let title: String?
    let semantic: String?

    static let pinSpan: CGFloat = 30

    private var resolvedTitle: String {
        title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Hide placeholder titles; show Home/Work, custom names, and other real labels.
    private var showsLabel: Bool {
        let value = resolvedTitle
        return !value.isEmpty && value != "Unnamed place" && value != "Place"
    }

    private var pinColor: Color {
        switch semantic {
        case "Home": return Palette.copper
        case "Work": return Palette.water
        default: return Palette.path
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            pinBody
            if showsLabel {
                Text(resolvedTitle)
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .foregroundStyle(Palette.parchment)
                    .shadow(color: .black.opacity(0.65), radius: 1.5, y: 0.5)
                    .lineLimit(1)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .mapPinLabelChip(cornerRadius: 12)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var pinBody: some View {
        ZStack {
            if let symbol = TimelineParser.symbolName(semantic) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(pinColor)
                    .frame(width: 20, height: 20)
            } else {
                Circle()
                    .fill(pinColor)
                    .frame(width: 16, height: 16)
                    .overlay {
                        Circle()
                            .stroke(Palette.parchment.opacity(0.92), lineWidth: 1.5)
                    }
            }
        }
        .frame(width: Self.pinSpan, height: Self.pinSpan)
        .mapGlassChip(cornerRadius: Self.pinSpan / 2)
        .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
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
