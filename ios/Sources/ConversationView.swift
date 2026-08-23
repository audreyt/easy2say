import SwiftUI
import Translation

/// Hosts BOTH translation directions of a conversation session at once.
///
/// A conversation needs primary→secondary and secondary→primary warm at the same
/// time: whoever speaks next decides the direction, and a cold start on the wrong
/// side would swallow the opening of their sentence. SwiftUI gives one
/// `TranslationSession` per `.translationTask`, so two configurations means two
/// modifiers, both anchored in the live view tree.
extension View {
    // `.translationTask` lands in iOS 18; the annotation records that floor without
    // a runtime branch that this target's iOS 26 minimum would make dead code.
    @available(iOS 18.0, *)
    func v2sConversationTranslationHost(engine: ConversationEngine) -> some View {
        self
            .translationTask(engine.primaryTranslationConfiguration) { session in
                await engine.runPrimaryTranslationHost(using: session)
            }
            .translationTask(engine.secondaryTranslationConfiguration) { session in
                await engine.runSecondaryTranslationHost(using: session)
            }
    }
}

/// Two-way, face-to-face conversation surface.
///
/// Each half renders the entire conversation in one reader's own language, so
/// neither person ever sees a script they cannot read. The half belonging to the
/// other person is flipped when the phone lies flat between two people.
struct ConversationView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: ConversationEngine
    let isStartDisabled: Bool
    let toggleSession: () -> Void
    let showSettings: () -> Void

    private var accent: Color {
        IOSTheme.color(model.iOSCaptionAccentColor)
    }

    /// A persisted language can outlive its on-device speech support, so the
    /// selection is validated against the live catalog rather than trusted.
    private var unsupportedLanguageID: String? {
        let supported = Set(model.speechLanguageOptions.map(\.id))
        for id in [model.conversationPrimaryLanguageID, model.conversationSecondaryLanguageID]
        where supported.contains(id) == false {
            return id
        }
        return nil
    }

    private var usesSameLanguage: Bool {
        model.conversationPrimaryLanguageID == model.conversationSecondaryLanguageID
    }

    private var warning: String? {
        if let unsupportedLanguageID {
            return model.localized(
                .conversationUnavailableFormat,
                LanguageCatalog.autonym(for: unsupportedLanguageID)
            )
        }
        if usesSameLanguage {
            return model.localized(.conversationSameLanguage)
        }
        return nil
    }

    private var isToggleDisabled: Bool {
        guard engine.isRunning == false else { return false }
        return isStartDisabled || warning != nil
    }

    var body: some View {
        GeometryReader { geometry in
            let isHorizontal = geometry.size.width > geometry.size.height

            if isHorizontal {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        half(for: .secondary)
                        ConversationHairline(isVertical: true, accent: accent)
                        half(for: .primary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    controlStrip
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
            } else {
                VStack(spacing: 0) {
                    half(for: .secondary)
                    controlStrip
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    half(for: .primary)
                }
            }
        }
        .animation(.easeInOut(duration: 0.24), value: model.conversationFaceToFace)
    }

    private func half(for side: ConversationSide) -> some View {
        ConversationHalf(
            model: model,
            engine: engine,
            side: side,
            accent: accent
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .rotationEffect(.degrees(isFlipped(side) ? 180 : 0))
    }

    /// Only the other person's half is ever flipped, and only when the two of them
    /// are reading the same screen from opposite sides of a table.
    private func isFlipped(_ side: ConversationSide) -> Bool {
        side == .secondary && model.conversationFaceToFace
    }

    private var controlStrip: some View {
        ConversationControlStrip(
            model: model,
            engine: engine,
            accent: accent,
            warning: warning,
            isToggleDisabled: isToggleDisabled,
            toggleSession: toggleSession,
            showSettings: showSettings
        )
    }
}

/// Compact two-option switch between the captions surface and conversation mode.
struct ConversationModeSwitch: View {
    let captionsTitle: String
    let conversationTitle: String
    let accent: Color
    let isConversationActive: Bool
    let select: (Bool) -> Void

    var body: some View {
        HStack(spacing: 2) {
            segment(title: captionsTitle, symbol: "captions.bubble", isActive: isConversationActive == false)
            segment(title: conversationTitle, symbol: "person.2.wave.2.fill", isActive: isConversationActive)
        }
        .padding(2)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay {
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.085), lineWidth: 0.5)
        }
        .animation(.easeOut(duration: 0.2), value: isConversationActive)
    }

    private func segment(title: String, symbol: String, isActive: Bool) -> some View {
        Button {
            select(isActive == false)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)

                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(isActive ? Color.black.opacity(0.82) : Color.white.opacity(0.62))
            .padding(.horizontal, 11)
            .frame(minHeight: 28)
            .background(
                Capsule(style: .continuous)
                    .fill(isActive ? accent.opacity(0.92) : Color.clear)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct ConversationHalf: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: ConversationEngine
    let side: ConversationSide
    let accent: Color

    @ScaledMetric(relativeTo: .largeTitle) private var baseCaptionSize: CGFloat = 30
    @ScaledMetric(relativeTo: .subheadline) private var baseHistorySize: CGFloat = 15

    private var scale: CGFloat {
        CGFloat(model.overlayStyle.overlayScaleFactor)
    }

    private var languageName: String {
        LanguageCatalog.autonym(for: engine.languageID(for: side))
    }

    private var draftText: String {
        engine.draftText(readBy: side)
    }

    /// Newest content: the live hypothesis while someone is mid-sentence, else the
    /// last committed turn.
    private var currentText: String {
        if draftText.isEmpty == false {
            return draftText
        }
        guard let last = engine.turns.last else { return "" }
        return engine.text(of: last, readBy: side)
    }

    /// Up to three turns of context, oldest first. The turn shown large is excluded.
    private var historyTurns: [ConversationTurn] {
        let candidates = draftText.isEmpty ? engine.turns.dropLast() : engine.turns[...]
        return Array(candidates.suffix(3))
    }

    private var isAwaitingFirstTurn: Bool {
        engine.turns.isEmpty && engine.primaryDraft.isEmpty && engine.secondaryDraft.isEmpty
    }

    private var holdsFloor: Bool {
        engine.phase == .listening && engine.floor == side
    }

    private var failureMessage: String? {
        guard case .failed(let message) = engine.phase else { return nil }
        return message
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Spacer(minLength: 0)

            if let failureMessage {
                failureContent(failureMessage)
            } else if isAwaitingFirstTurn {
                emptyHint
            } else {
                transcriptContent
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(holdsFloor ? accent.opacity(0.055) : Color.clear)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(accent.opacity(holdsFloor ? 0.46 : 0.0), lineWidth: 1)
        }
        .shadow(color: accent.opacity(holdsFloor ? 0.18 : 0.0), radius: 16)
        .animation(.easeOut(duration: 0.22), value: holdsFloor)
        .contentShape(Rectangle())
        .onTapGesture {
            engine.claimFloor(side)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.localized(.conversationClaimFloorFormat, languageName))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            engine.claimFloor(side)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            languageChip

            if holdsFloor {
                Text(model.localized(.conversationSpeakingFormat, languageName))
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .transition(.opacity)
            }

            Spacer(minLength: 0)
        }
    }

    private var languageChip: some View {
        Text(languageName)
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundStyle(accent.opacity(0.92))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(accent.opacity(0.09))
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(accent.opacity(0.20), lineWidth: 0.5)
            }
    }

    private var transcriptContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(historyTurns) { turn in
                historyRow(turn)
            }

            Text(currentText)
                .font(
                    .system(
                        size: baseCaptionSize * scale,
                        weight: draftText.isEmpty ? .semibold : .medium,
                        design: .rounded
                    )
                )
                .foregroundStyle(accent.opacity(draftText.isEmpty ? 1.0 : 0.70))
                .lineLimit(4)
                .minimumScaleFactor(0.5)
                .allowsTightening(true)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.2), value: currentText)
        }
    }

    private func historyRow(_ turn: ConversationTurn) -> some View {
        HStack(alignment: .top, spacing: 9) {
            // The rule tells "my words" from "their words" without repeating a
            // language name on every line.
            Capsule(style: .continuous)
                .fill(turn.side == side ? accent.opacity(0.34) : Color.white.opacity(0.16))
                .frame(width: 2)
                .accessibilityHidden(true)

            Text(engine.text(of: turn, readBy: side))
                .font(.system(size: baseHistorySize * scale, weight: .regular, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.42))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyHint: some View {
        Text(model.localized(.conversationEmptyHint))
            .font(.system(.subheadline, design: .rounded))
            .foregroundStyle(IOSTheme.secondaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func failureContent(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.red.opacity(0.90))
                .accessibilityHidden(true)

            Text(message)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(Color.red.opacity(0.88))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ConversationControlStrip: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: ConversationEngine
    let accent: Color
    let warning: String?
    let isToggleDisabled: Bool
    let toggleSession: () -> Void
    let showSettings: () -> Void

    private var toggleTitle: String {
        model.localized(engine.isRunning ? .conversationStop : .conversationStart)
    }

    private var hasContent: Bool {
        engine.turns.isEmpty == false
    }

    var body: some View {
        VStack(spacing: 10) {
            statusLine

            HStack(spacing: 12) {
                ControlIconButton(
                    symbol: "arrow.counterclockwise",
                    title: model.localized(.conversationClear),
                    action: engine.clearTurns
                )
                .disabled(hasContent == false)
                .opacity(hasContent ? 1.0 : 0.42)

                SessionCapsuleButton(
                    title: toggleTitle,
                    isLive: engine.phase == .listening,
                    showsActivity: engine.phase == .preparing,
                    isDisabled: isToggleDisabled,
                    accent: accent,
                    action: toggleSession
                )
                .frame(maxWidth: 210)

                ControlIconButton(
                    symbol: "gearshape.fill",
                    title: model.localized(.iosSettings),
                    action: showSettings
                )
            }
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .premiumPanel(cornerRadius: 28)
        .tint(accent)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let warning {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.red.opacity(0.92))
                    .accessibilityHidden(true)

                Text(warning)
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(Color.red.opacity(0.88))
                    .lineLimit(2)

                Spacer(minLength: 0)
            }
            .transition(.opacity)
        } else if let phaseTitle {
            HStack(spacing: 8) {
                Circle()
                    .fill(engine.phase == .listening ? accent : Color.white.opacity(0.34))
                    .frame(width: 6, height: 6)
                    .shadow(color: accent.opacity(engine.phase == .listening ? 0.8 : 0.0), radius: 5)
                    .accessibilityHidden(true)

                Text(phaseTitle)
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .lineLimit(2)

                Spacer(minLength: 0)

                if engine.phase == .preparing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .transition(.opacity)
        } else {
            languagePairLine
        }
    }

    private var phaseTitle: String? {
        switch engine.phase {
        case .preparing:
            return model.localized(.conversationPreparing)
        case .listening:
            return model.localized(.conversationListening)
        case .failed(let message):
            return message
        case .idle:
            return nil
        }
    }

    private var languagePairLine: some View {
        HStack(spacing: 7) {
            Text(LanguageCatalog.autonym(for: engine.languageID(for: .primary)))
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(accent.opacity(0.72))
                .accessibilityHidden(true)
            Text(LanguageCatalog.autonym(for: engine.languageID(for: .secondary)))

            Spacer(minLength: 0)
        }
        .font(.system(.caption, design: .rounded, weight: .medium))
        .foregroundStyle(Color.white.opacity(0.58))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

private struct ConversationHairline: View {
    let isVertical: Bool
    let accent: Color

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, accent.opacity(0.62), Color.white.opacity(0.08), .clear],
                    startPoint: isVertical ? .top : .leading,
                    endPoint: isVertical ? .bottom : .trailing
                )
            )
            .frame(
                width: isVertical ? 0.5 : nil,
                height: isVertical ? nil : 0.5
            )
            .accessibilityHidden(true)
    }
}
