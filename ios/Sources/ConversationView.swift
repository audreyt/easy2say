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
    let showCaptions: () -> Void

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

            VStack(spacing: 8) {
                if isHorizontal {
                    HStack(spacing: 10) {
                        half(for: .secondary)
                        half(for: .primary)
                    }
                } else {
                    VStack(spacing: 10) {
                        half(for: .secondary)
                        half(for: .primary)
                    }
                }

                controlStrip
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
            accent: IOSTheme.brand,
            warning: warning,
            isToggleDisabled: isToggleDisabled,
            toggleSession: toggleSession,
            showSettings: showSettings,
            showCaptions: showCaptions
        )
    }
}

/// One compact control flips between captions and two-way conversation without
/// consuming a dedicated row of transcript space.
struct ConversationModeSwitch: View {
    let captionsTitle: String
    let conversationTitle: String
    let accent: Color
    let isConversationActive: Bool
    let destinationAccessibilityLabel: String
    let select: (Bool) -> Void


    private var currentTitle: String {
        isConversationActive ? conversationTitle : captionsTitle
    }

    private var destinationSymbol: String {
        isConversationActive ? "captions.bubble.fill" : "person.2.wave.2.fill"
    }

    var body: some View {
        Button {
            select(isConversationActive == false)
        } label: {
            Image(systemName: destinationSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent.opacity(0.92))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(IOSTheme.primaryText.opacity(0.055))
                )
                .overlay {
                    Circle()
                        .stroke(accent.opacity(0.20), lineWidth: 0.5)
                }
                // The disc reads at 32pt; the hit area stays at the 44pt minimum.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(destinationAccessibilityLabel)
        .accessibilityValue(currentTitle)
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

    private var readerInterfaceLanguageID: String {
        let languageID = engine.languageID(for: side)
        return LanguageCatalog.interface.contains(where: { $0.id == languageID })
            ? languageID
            : model.resolvedInterfaceLanguageID
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
        engine.phase == .listening
            && engine.floor == side
            && engine.draft(for: side).sourceText.isEmpty == false
    }

    private var failureMessage: String? {
        guard case .failed(let message) = engine.phase else { return nil }
        return message
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if holdsFloor {
                header
            }
            if let failureMessage {
                failureContent(failureMessage)
            } else if isAwaitingFirstTurn {
                emptyHint
            } else {
                transcriptContent
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    holdsFloor
                        ? IOSTheme.brand.opacity(0.10)
                        : IOSTheme.elevated.opacity(0.78)
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    holdsFloor ? IOSTheme.brand.opacity(0.52) : IOSTheme.hairline,
                    lineWidth: holdsFloor ? 1 : 0.5
                )
        }
        .shadow(color: IOSTheme.brand.opacity(holdsFloor ? 0.20 : 0.0), radius: 16)
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
        HStack(spacing: 7) {
            Image(systemName: "mic.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(IOSTheme.brand)
                .accessibilityHidden(true)

            Text(model.localized(.conversationSpeakingFormat, languageName))
                .font(.system(.caption2, design: .rounded, weight: .semibold))
                .foregroundStyle(IOSTheme.brand)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .transition(.opacity)

            Spacer(minLength: 0)
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
                .foregroundStyle(draftText.isEmpty ? accent : IOSTheme.secondaryText)
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
                .fill(turn.side == side ? IOSTheme.brand.opacity(0.38) : IOSTheme.primaryText.opacity(0.16))
                .frame(width: 2)
                .accessibilityHidden(true)

            Text(engine.text(of: turn, readBy: side))
                .font(.system(size: baseHistorySize * scale, weight: .regular, design: .rounded))
                .foregroundStyle(IOSTheme.tertiaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyHint: some View {
        VStack(spacing: 14) {
            Easy2sayMark()
                .fill(IOSTheme.brand.opacity(0.42))
                .frame(width: 46, height: 46 / Easy2sayMark().aspectRatio)
                .accessibilityHidden(true)

            Text(
                AppLocalization.string(
                    .conversationEmptyHint,
                    languageID: readerInterfaceLanguageID
                )
            )
            .font(.system(.subheadline, design: .rounded))
            .foregroundStyle(IOSTheme.secondaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func failureContent(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(IOSTheme.alert)
                .accessibilityHidden(true)

            Text(message)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(IOSTheme.alert)
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
    let showCaptions: () -> Void

    private var toggleTitle: String {
        model.localized(engine.isRunning ? .conversationStop : .conversationStart)
    }

    private var hasContent: Bool {
        engine.turns.isEmpty == false
    }

    private var modeFlip: some View {
        ConversationModeSwitch(
            captionsTitle: model.localized(.conversationCaptionsMode),
            conversationTitle: model.localized(.conversationMode),
            accent: accent,
            isConversationActive: true,
            destinationAccessibilityLabel: model.localized(.switchToCaptionsMode),
            select: { isConversationActive in
                if isConversationActive == false {
                    showCaptions()
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                statusLine
                    .frame(maxWidth: .infinity)
                modeFlip
            }
            HStack(spacing: 28) {
                ControlIconButton(
                    symbol: "gearshape.fill",
                    title: model.localized(.iosSettings),
                    action: showSettings
                )

                SessionCapsuleButton(
                    title: toggleTitle,
                    isLive: engine.phase == .listening,
                    showsActivity: engine.phase == .preparing,
                    isDisabled: isToggleDisabled,
                    accent: accent,
                    action: toggleSession
                )

                ControlIconButton(
                    symbol: "arrow.counterclockwise",
                    title: model.localized(.conversationClear),
                    action: engine.clearTurns
                )
                .disabled(hasContent == false)
                .opacity(hasContent ? 1.0 : 0.55)
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
            Button(action: showSettings) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(IOSTheme.alert)
                        .accessibilityHidden(true)

                    Text(warning)
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(IOSTheme.alert)
                        .lineLimit(2)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(IOSTheme.alert.opacity(0.66))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(warning)
            .transition(.opacity)
        } else if let phaseTitle {
            HStack(spacing: 8) {
                BrandStatusMark(
                    isLive: engine.phase == .listening,
                    isError: phaseIsFailed
                )

                Text(phaseTitle)
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(IOSTheme.secondaryText)
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

    private var phaseIsFailed: Bool {
        if case .failed = engine.phase {
            return true
        }
        return false
    }

    private var languagePairLine: some View {
        HStack(spacing: 8) {
            languagePill(for: .primary)

            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(accent.opacity(0.72))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(accent.opacity(0.09))
                )
                .accessibilityHidden(true)

            languagePill(for: .secondary)

            Spacer(minLength: 0)
        }
    }

    private func languagePill(for side: ConversationSide) -> some View {
        Text(LanguageCatalog.autonym(for: engine.languageID(for: side)))
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundStyle(IOSTheme.primaryText.opacity(0.78))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(accent.opacity(0.075))
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(accent.opacity(0.16), lineWidth: 0.5)
            }
    }
}
