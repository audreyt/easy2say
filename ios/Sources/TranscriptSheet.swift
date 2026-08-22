import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct TranscriptSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var accent: Color {
        IOSTheme.color(model.iOSCaptionAccentColor)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                IOSTheme.background(accent: accent)
                    .ignoresSafeArea()

                if model.transcriptEntries.isEmpty {
                    emptyState
                } else {
                    transcriptList
                }
            }
            .navigationTitle(model.localized(.transcript))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(model.localized(.clear), role: .destructive) {
                        model.clearTranscript()
                    }
                    .disabled(model.transcriptEntries.isEmpty)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(model.localized(.done)) {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .safeAreaInset(edge: .bottom) {
                copyBar
            }
        }
        .environment(\.locale, model.interfaceLocale)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var transcriptList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(Array(model.transcriptEntries.enumerated()), id: \.element.id) { index, entry in
                    TranscriptRow(
                        index: index + 1,
                        entry: entry,
                        accent: accent,
                        sourceLabel: model.localized(.origin),
                        translationLabel: model.localized(.translation)
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(accent.opacity(0.58))
                .accessibilityHidden(true)

            Text(model.localized(.transcript))
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.90))

            Text(model.localized(.iosTranscriptEmpty))
                .font(.system(.body, design: .rounded))
                .foregroundStyle(IOSTheme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
    }

    private var copyBar: some View {
        Button(action: copyAll) {
            Label(model.localized(.iosCopyAll), systemImage: "doc.on.doc")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 46)
                .foregroundStyle(Color.black.opacity(0.82))
                .background(
                    Capsule(style: .continuous)
                        .fill(accent)
                )
        }
        .buttonStyle(.plain)
        .disabled(model.transcriptEntries.isEmpty)
        .opacity(model.transcriptEntries.isEmpty ? 0.42 : 1.0)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func copyAll() {
        let text = model.transcriptEntries
            .map { entry in
                if entry.translatedText.isEmpty {
                    return entry.sourceText
                }
                return "\(entry.sourceText)\n\(entry.translatedText)"
            }
            .joined(separator: "\n\n")

        #if canImport(UIKit)
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}

private struct TranscriptRow: View {
    let index: Int
    let entry: TranscriptEntry
    let accent: Color
    let sourceLabel: String
    let translationLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%02d", index))
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(accent.opacity(0.78))

                Spacer()
            }

            transcriptLine(label: sourceLabel, text: entry.sourceText, emphasized: false)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, accent.opacity(0.30), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 0.5)
                .accessibilityHidden(true)

            transcriptLine(
                label: translationLabel,
                text: entry.translatedText.isEmpty ? "…" : entry.translatedText,
                emphasized: true
            )
        }
        .padding(16)
        .premiumPanel(cornerRadius: 19)
    }

    private func transcriptLine(label: String, text: String, emphasized: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(Color.white.opacity(0.38))

            Text(text)
                .font(.system(.body, design: .rounded, weight: emphasized ? .semibold : .regular))
                .foregroundStyle(emphasized ? accent : Color.white.opacity(0.82))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
