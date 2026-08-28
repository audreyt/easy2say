import AppKit
import SwiftUI

struct AudienceDisplayView: View {
    @ObservedObject var model: AppModel
    let onExit: () -> Void

    @State private var isHovering = false
    @State private var hoverDismissTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()

            GeometryReader { proxy in
                let horizontalPadding = max(32, (proxy.size.width - maxContentWidth(for: proxy.size.width)) / 2)
                let bottomPadding = max(36, proxy.size.height * 0.06)
                let topPadding = max(32, proxy.size.height * 0.05)

                CaptionFlowContentView(
                    model: model,
                    showsScrollbarPadding: false,
                    updatesModelHistoryVisibleCount: false,
                    reservesColumnHeaderSpace: false,
                    columnHeaderOpacity: isHovering ? 1.0 : 0.0
                )
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, bottomPadding)
                .padding(.top, topPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            AudienceDisplayExitAffordance(
                title: exitButtonTitle,
                action: onExit
            )
            .opacity(isHovering ? 1.0 : 0.0)
            .accessibilityHidden(isHovering == false)
            .animation(.easeInOut(duration: 0.25), value: isHovering)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if isHovering == false {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isHovering = true
                    }
                }
                hoverDismissTask?.cancel()
                hoverDismissTask = Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if Task.isCancelled == false {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            isHovering = false
                        }
                    }
                }
            case .ended:
                hoverDismissTask?.cancel()
                withAnimation(.easeInOut(duration: 0.35)) {
                    isHovering = false
                }
            }
        }
        .modifier(OverlayTranslationHostModifier(model: model, role: .audienceDisplay))
    }

    private var exitButtonTitle: String {
        let baseExit = model.localized(.hideAudienceDisplay)
        return "\(baseExit) (Esc)"
    }

    private func maxContentWidth(for screenWidth: CGFloat) -> CGFloat {
        min(screenWidth * 0.88, 1600)
    }
}

struct AudienceDisplayExitAffordance: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.white.opacity(0.88))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                Capsule()
                    .fill(Color.black.opacity(0.70))
                    .overlay {
                        Capsule()
                            .stroke(Color.white.opacity(0.24), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}
