import AppKit
import SwiftUI

/// Keep glass behind content so photos and small type stay sharp.
extension View {
    func pastesGlass(cornerRadius: CGFloat, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(PastesGlassSurface(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }
}

private struct PastesGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if reduceTransparency {
                    shape.fill(Color(nsColor: .controlBackgroundColor))
                        .overlay { shape.fill(tint ?? .clear) }
                } else {
                    ZStack {
                        shape.fill(.clear)
                            .glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
                        shape.fill(scheme == .dark ? Color(white: 0.08).opacity(0.28) : Color(white: 0.58).opacity(0.12))
                        shape.fill(LinearGradient(colors: [.white.opacity(0.08), .clear, .black.opacity(0.025)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                    .clipShape(shape)
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [
                        .white.opacity(scheme == .dark ? 0.65 : 0.95),
                        .white.opacity(scheme == .dark ? 0.16 : 0.34),
                        .white.opacity(0.08),
                        .white.opacity(scheme == .dark ? 0.28 : 0.66)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: contrast == .increased ? 1.3 : 0.85)
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.inset(by: 1)
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.35 : 0.06), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}

enum PastesGlassProminence {
    case standard, accent, destructive
}

/// Lightweight controls share their parent's blur instead of creating a blur
/// view for every button in a scrolling list.
struct PastesGlassButtonStyle: ButtonStyle {
    var prominence: PastesGlassProminence = .standard
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewState private var hovered = false

    private var tint: Color {
        switch prominence {
        case .standard: .primary
        case .accent: .blue
        case .destructive: .red
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 6 : 8)
            .background {
                Capsule(style: .continuous)
                    .fill(reduceTransparency ? Color(nsColor: .controlBackgroundColor)
                          : Color.white.opacity(scheme == .dark ? 0.09 : 0.47))
                    .overlay {
                        Capsule(style: .continuous)
                            .fill(tint.opacity(prominence == .standard ? (hovered ? 0.08 : 0.015) : (hovered ? 0.18 : 0.10)))
                    }
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.38 : 0.9),
                                                                 .white.opacity(0.1), .white.opacity(0.32)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
                    }
                    .overlay {
                        if contrast == .increased {
                            Capsule(style: .continuous).strokeBorder(tint.opacity(0.5), lineWidth: 1)
                        }
                    }
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.12 : 0.035), radius: 4, y: 2)
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
            .onHover { hovered = $0 }
    }
}

struct PastesGlassIcon: View {
    let symbol: String
    var tint: Color = .blue
    var size: CGFloat = 34
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background {
                Circle().fill(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.96 : 1), .white.opacity(0.80)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay { Circle().strokeBorder(.white.opacity(0.8), lineWidth: 0.7) }
                    .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
            }
            .accessibilityHidden(true)
    }
}

/// A single native frosted surface for text-heavy windows.
struct PastesWindowBackground: View {
    var cornerRadius: CGFloat = 28
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                PastesWindowGlass(cornerRadius: cornerRadius, dark: scheme == .dark)
                (scheme == .dark ? Color(white: 0.05).opacity(0.3) : Color(white: 0.64).opacity(0.10))
                LinearGradient(colors: [.white.opacity(0.12), .clear, .black.opacity(0.025)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.52 : 0.9), .white.opacity(0.1), .white.opacity(0.34)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.85)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PastesWindowGlass: NSViewRepresentable {
    let cornerRadius: CGFloat
    let dark: Bool
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        view.tintColor = tint
        view.cornerRadius = cornerRadius
        return view
    }
    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.cornerRadius = cornerRadius
        view.tintColor = tint
    }
    private var tint: NSColor {
        NSColor(calibratedWhite: dark ? 0.16 : 0.78, alpha: dark ? 0.22 : 0.18)
    }
}
