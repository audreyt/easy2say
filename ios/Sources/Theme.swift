import SwiftUI

enum IOSTheme {
    /// Deep plum-black. Every surface below is warm, never neutral grey.
    static let canvas = EasyBrand.ink
    static let elevated = EasyBrand.cocoa
    static let hairline = EasyBrand.peach.opacity(0.16)
    static let primaryText = EasyBrand.cream
    static let secondaryText = EasyBrand.cream.opacity(0.72)
    /// History and other deliberately recessive text.
    static let tertiaryText = EasyBrand.cream.opacity(0.50)
    /// Live/recording affordances and the brand mark itself.
    static let brand = EasyBrand.peach
    static let alert = EasyBrand.alert

    /// Plum wash behind every screen. The caption accent is only a whisper here so
    /// the app keeps one identity whichever caption colour the reader picks.
    static func background(accent: Color) -> some View {
        ZStack {
            canvas
            RadialGradient(
                colors: [EasyBrand.plum.opacity(0.92), EasyBrand.plum.opacity(0.30), .clear],
                center: .topLeading,
                startRadius: 8,
                endRadius: 660
            )
            RadialGradient(
                colors: [EasyBrand.peach.opacity(0.085), .clear],
                center: UnitPoint(x: 0.94, y: 0.06),
                startRadius: 4,
                endRadius: 420
            )
            RadialGradient(
                colors: [accent.opacity(0.05), .clear],
                center: UnitPoint(x: 0.12, y: 0.96),
                startRadius: 4,
                endRadius: 380
            )
            LinearGradient(
                colors: [.clear, EasyBrand.ink.opacity(0.62)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    static func color(_ value: OverlayColor) -> Color {
        Color(
            .sRGB,
            red: value.red,
            green: value.green,
            blue: value.blue,
            opacity: value.alpha
        )
    }
}

enum CaptionAccentPreset: String, CaseIterable, Identifiable {
    case ice
    case mint
    case violet
    case coral

    var id: String { rawValue }

    var components: (red: Double, green: Double, blue: Double) {
        switch self {
        case .ice:
            return (1.00, 1.00, 1.00)
        case .mint:
            return (0.46, 0.94, 0.75)
        case .violet:
            return (0.72, 0.64, 1.00)
        case .coral:
            // The Easy2say peach, so the brand colour is also a caption colour.
            return (0.957, 0.643, 0.600)
        }
    }

    var color: Color {
        let value = components
        return Color(red: value.red, green: value.green, blue: value.blue)
    }

    var overlayColor: OverlayColor {
        let value = components
        return OverlayColor(red: value.red, green: value.green, blue: value.blue)
    }

    var localizationKey: AppTextKey {
        switch self {
        case .ice:
            return .iosAccentIce
        case .mint:
            return .iosAccentMint
        case .violet:
            return .iosAccentViolet
        case .coral:
            return .iosAccentCoral
        }
    }

    static func closest(to color: OverlayColor) -> CaptionAccentPreset {
        allCases.min { lhs, rhs in
            lhs.distanceSquared(to: color) < rhs.distanceSquared(to: color)
        } ?? .ice
    }

    private func distanceSquared(to color: OverlayColor) -> Double {
        let value = components
        let red = value.red - color.red
        let green = value.green - color.green
        let blue = value.blue - color.blue
        return red * red + green * green + blue * blue
    }
}


private struct PremiumPanelModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(IOSTheme.elevated.opacity(0.90))
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(IOSTheme.hairline, lineWidth: 0.5)
            }
            .shadow(color: EasyBrand.ink.opacity(0.52), radius: 24, y: 12)
    }
}

extension View {
    func premiumPanel(cornerRadius: CGFloat = 24) -> some View {
        modifier(PremiumPanelModifier(cornerRadius: cornerRadius))
    }
}

/// The mark doubling as the session indicator: peach and breathing while live,
/// recessive when idle, warm red on failure. Replaces a bare status dot, so it
/// stays decorative for assistive technology.
struct BrandStatusMark: View {
    let isLive: Bool
    let isError: Bool
    var width: CGFloat = 20

    /// Idle stays recessive but not so faint that the bubble's slots and tail smear
    /// together at status-line size.
    private var tint: Color {
        if isError { return IOSTheme.alert }
        return isLive ? IOSTheme.brand : EasyBrand.cream.opacity(0.52)
    }

    var body: some View {
        let mark = Easy2sayMark()

        mark
            .fill(tint)
            .frame(width: width, height: width / mark.aspectRatio)
            .shadow(color: IOSTheme.brand.opacity(isLive ? 0.55 : 0.0), radius: 5)
            .animation(.easeInOut(duration: 0.24), value: isLive)
            .accessibilityHidden(true)
    }
}
