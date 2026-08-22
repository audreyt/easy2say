import SwiftUI

enum IOSTheme {
    static let canvas = Color(red: 0.018, green: 0.021, blue: 0.028)
    static let elevated = Color(red: 0.055, green: 0.061, blue: 0.078)
    static let hairline = Color.white.opacity(0.10)
    static let secondaryText = Color.white.opacity(0.62)

    static func background(accent: Color) -> some View {
        ZStack {
            canvas
            RadialGradient(
                colors: [accent.opacity(0.12), accent.opacity(0.025), .clear],
                center: .topLeading,
                startRadius: 8,
                endRadius: 620
            )
            LinearGradient(
                colors: [.clear, Color.black.opacity(0.38)],
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
            return (1.00, 0.62, 0.48)
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

/// Compact product wordmark. Renders as the single word `v2s-ios`, with the
/// platform suffix tinted so the full name stays legible at caption size.
struct BrandWordmark: View {
    let accent: Color

    var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: "v2s")
                .foregroundStyle(Color.white.opacity(0.92))
            Text(verbatim: "-ios")
                .foregroundStyle(accent.opacity(0.88))
        }
        .font(.system(size: 15, weight: .semibold, design: .rounded))
        .tracking(-0.2)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "v2s-ios"))
    }
}

struct PrivacyBadge: View {
    let title: String
    let accent: Color

    var body: some View {
        Label(title, systemImage: "lock.fill")
            .font(.system(.caption2, design: .rounded, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.78))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.055))
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(accent.opacity(0.20), lineWidth: 0.5)
            }
            .accessibilityElement(children: .combine)
    }
}

private struct PremiumPanelModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(IOSTheme.elevated.opacity(0.88))
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(IOSTheme.hairline, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.28), radius: 22, y: 12)
    }
}

extension View {
    func premiumPanel(cornerRadius: CGFloat = 24) -> some View {
        modifier(PremiumPanelModifier(cornerRadius: cornerRadius))
    }
}
