#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// Easy2Say brand palette, shared by every platform surface.
///
/// Plum is the ground the paired-voice mark sits on, peach is the voice itself, and
/// everything else is derived from those two so the app cannot drift into a second
/// accent family. Neutrals are tinted, never pure black or white.
enum EasyBrand {
    /// #4d2a33 — the mark's background.
    static let plum = Color(.sRGB, red: 0.302, green: 0.165, blue: 0.200, opacity: 1.0)
    /// #f4a499 — the mark's bubble; recording and other live affordances.
    static let peach = Color(.sRGB, red: 0.957, green: 0.643, blue: 0.600, opacity: 1.0)
    /// Deep plum-black app canvas.
    static let ink = Color(.sRGB, red: 0.086, green: 0.055, blue: 0.067, opacity: 1.0)
    /// Warm cocoa panel, one step above the canvas.
    static let cocoa = Color(.sRGB, red: 0.165, green: 0.102, blue: 0.125, opacity: 1.0)
    /// Warm off-white for primary text.
    static let cream = Color(.sRGB, red: 0.988, green: 0.957, blue: 0.949, opacity: 1.0)
    /// Warm red that still clears 4.5:1 against ``cocoa``.
    static let alert = Color(.sRGB, red: 1.000, green: 0.451, blue: 0.427, opacity: 1.0)

    /// Controls need opposite brand poles across system appearances: dark plum is
    /// legible on light surfaces, while peach stays legible on dark materials.
    static func controlTint(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? peach : plum
    }
}

/// The one Easy2Say mark: a rounded speech bubble with an integrated lower-left
/// tail, carrying a 2-column × 3-row field of rounded slots knocked out of it. The
/// two columns, split by a clear central gutter, are the conversation hint the app
/// icon has always had; the bubble is what makes the tray glyph read at 18 pt.
///
/// This is the single source of the geometry. The app icons, the in-app
/// ``BrandStatusMark`` and the menu-bar template image all render this one path, so
/// they cannot drift apart. Units below are the mark's own design box.
struct Easy2sayMark: Shape {
    /// Bubble body, excluding the tail.
    private static let bodySize = CGSize(width: 720, height: 632)
    private static let cornerRadius: CGFloat = 132
    /// How far the tail hangs below the body.
    private static let tailDrop: CGFloat = 132
    /// The tail: where its two edges leave the body's bottom edge, and the corner
    /// its point turns around.
    private static let tailLeftX: CGFloat = 148
    private static let tailRightX: CGFloat = 300
    private static let tailCornerX: CGFloat = 172
    /// Radius of the tail's point.
    private static let tailTipRadius: CGFloat = 44
    /// The slot field is centred in the bubble body, not in the full bounding box:
    /// the tail is localised to one corner and does not carry the whole width.
    private static let fieldDrop: CGFloat = 0
    /// Slot field: two columns of three, mirrored about the gutter.
    private static let slotHeight: CGFloat = 72
    private static let slotRowPitch: CGFloat = 128
    private static let fieldInset: CGFloat = 132
    private static let gutter: CGFloat = 56
    /// The bottom row is a little shorter on its outer end, the way a last line of
    /// text is — enough to hint at speech, not enough to hollow out the lower band.
    private static let shortRowTrim: CGFloat = 30

    private static let designSize = CGSize(
        width: bodySize.width,
        height: bodySize.height + tailDrop
    )

    var aspectRatio: CGFloat {
        Self.designSize.width / Self.designSize.height
    }

    func path(in rect: CGRect) -> Path {
        let scale = min(
            rect.width / Self.designSize.width,
            rect.height / Self.designSize.height
        )
        let drawnSize = CGSize(
            width: Self.designSize.width * scale,
            height: Self.designSize.height * scale
        )

        return Self.markPath
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .applying(
                CGAffineTransform(
                    translationX: rect.midX - drawnSize.width / 2,
                    y: rect.midY - drawnSize.height / 2
                )
            )
    }

    private static let markPath: Path = envelope.subtracting(slotField)

    /// Rounded bubble plus tail, unioned so the tail reads as part of the shell
    /// rather than a triangle parked underneath it.
    private static let envelope: Path = {
        let body = Path(
            roundedRect: CGRect(origin: .zero, size: bodySize),
            cornerRadius: cornerRadius,
            style: .continuous
        )

        // The tail is two straight edges — steep on the outside, diagonal on the
        // inside — turning through one rounded point. Its last leg runs back through
        // the body's interior, where the union hides it: no seam, no stray outline.
        let attachLeft = CGPoint(x: tailLeftX, y: bodySize.height)
        let attachRight = CGPoint(x: tailRightX, y: bodySize.height)
        let tip = CGPoint(x: tailCornerX, y: bodySize.height + tailDrop)
        let shelf = bodySize.height - cornerRadius

        var tail = Path()
        tail.move(to: attachLeft)
        tail.addLine(to: point(from: tip, toward: attachLeft, distance: tailTipRadius))
        tail.addQuadCurve(
            to: point(from: tip, toward: attachRight, distance: tailTipRadius),
            control: tip
        )
        tail.addLine(to: attachRight)
        tail.addLine(to: CGPoint(x: attachRight.x, y: shelf))
        tail.addLine(to: CGPoint(x: attachLeft.x, y: shelf))
        tail.closeSubpath()

        return body.union(tail)
    }()

    private static let slotField: Path = {
        let radius = slotHeight / 2
        let columnWidth = (bodySize.width - fieldInset * 2 - gutter) / 2
        let fieldHeight = slotRowPitch * 2 + slotHeight
        let firstRowTop = (bodySize.height - fieldHeight) / 2 + fieldDrop

        var field = Path()
        for row in 0 ..< 3 {
            let trim = row == 2 ? shortRowTrim : 0
            let top = firstRowTop + CGFloat(row) * slotRowPitch

            // Outer ends vary, inner ends stay pinned to the gutter so it reads as
            // one clean channel down the middle.
            field.addPath(
                Path(
                    roundedRect: CGRect(
                        x: fieldInset + trim,
                        y: top,
                        width: columnWidth - trim,
                        height: slotHeight
                    ),
                    cornerRadius: radius,
                    style: .circular
                )
            )
            field.addPath(
                Path(
                    roundedRect: CGRect(
                        x: fieldInset + columnWidth + gutter,
                        y: top,
                        width: columnWidth - trim,
                        height: slotHeight
                    ),
                    cornerRadius: radius,
                    style: .circular
                )
            )
        }
        return field
    }()

    private static func point(
        from origin: CGPoint,
        toward target: CGPoint,
        distance: CGFloat
    ) -> CGPoint {
        let dx = target.x - origin.x
        let dy = target.y - origin.y
        let length = max((dx * dx + dy * dy).squareRoot(), 0.0001)
        return CGPoint(
            x: origin.x + dx / length * distance,
            y: origin.y + dy / length * distance
        )
    }
}

struct SettingsControlRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            content()
        }
    }
}

struct CommonLanguageMenuPicker: View {
    let interfaceLanguageID: String
    let options: [LanguageOption]
    @Binding var selection: String

    init(
        interfaceLanguageID: String,
        options: [LanguageOption] = LanguageCatalog.common,
        selection: Binding<String>
    ) {
        self.interfaceLanguageID = interfaceLanguageID
        self.options = options
        self._selection = selection
    }

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options) { option in
                Text(option.localizedDisplayName(in: interfaceLanguageID)).tag(option.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }
}

struct DefaultableLanguageMenuPicker: View {
    let interfaceLanguageID: String
    let options: [LanguageOption]
    let defaultTitle: String
    @Binding var selection: String?

    init(
        interfaceLanguageID: String,
        options: [LanguageOption] = LanguageCatalog.common,
        defaultTitle: String,
        selection: Binding<String?>
    ) {
        self.interfaceLanguageID = interfaceLanguageID
        self.options = options
        self.defaultTitle = defaultTitle
        self._selection = selection
    }

    var body: some View {
        Picker("", selection: $selection) {
            Text(defaultTitle).tag(nil as String?)
            ForEach(options) { option in
                Text(option.localizedDisplayName(in: interfaceLanguageID)).tag(Optional(option.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }
}

struct SourceMenuPicker: View {
    let sources: [InputSource]
    let interfaceLanguageID: String
    let emptyTitle: String
    @Binding var selection: String?

    var body: some View {
        Picker("", selection: $selection) {
            Text(emptyTitle).tag(nil as String?)
            ForEach(sources) { source in
                Text("\(source.category.displayName(in: interfaceLanguageID)) · \(source.name)")
                    .tag(Optional(source.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }
}

struct SourceMultiSelectPicker: View {
    let sources: [InputSource]
    let interfaceLanguageID: String
    let emptyTitle: String
    @Binding var selection: Set<String>
    @State private var isPresented = false

    private var controlBackgroundColor: Color {
#if os(macOS)
        return Color(nsColor: .controlColor)
#else
        return Color(uiColor: .secondarySystemBackground)
#endif
    }

    private var controlSeparatorColor: Color {
#if os(macOS)
        return Color(nsColor: .separatorColor)
#else
        return Color(uiColor: .separator)
#endif
    }

    private var allSourceIDs: Set<String> {
        Set(sources.map(\.id))
    }

    private var internalSources: [InputSource] {
        sources.filter { $0.category == .application }
    }

    private var deviceSources: [InputSource] {
        sources.filter { $0.category == .microphone }
    }

    private var internalSourceIDs: Set<String> {
        Set(internalSources.map(\.id))
    }

    private var deviceSourceIDs: Set<String> {
        Set(deviceSources.map(\.id))
    }

    private var isAllSourcesSelected: Bool {
        sources.isEmpty == false && selection == allSourceIDs
    }

    private var isAllInternalSourcesSelected: Bool {
        internalSourceIDs.isEmpty == false && internalSourceIDs.isSubset(of: selection)
    }

    private var isAllDeviceSourcesSelected: Bool {
        deviceSourceIDs.isEmpty == false && deviceSourceIDs.isSubset(of: selection)
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Text(menuTitle)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 12)
                .padding(.trailing, 30)
                .frame(minWidth: 180, minHeight: 32, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(controlBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(controlSeparatorColor.opacity(0.35), lineWidth: 0.5)
            )
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 11)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                if sources.isEmpty {
                    Text(emptyTitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(16)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            if internalSources.isEmpty == false {
                                Button {
                                    toggleAllInternalSources()
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: isAllInternalSourcesSelected ? "checkmark" : "")
                                            .frame(width: 12, alignment: .leading)
                                            .foregroundStyle(Color.accentColor)
                                        Text(AppLocalization.string(.allInternalSources, languageID: interfaceLanguageID))
                                            .font(.callout)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                            }

                            if deviceSources.isEmpty == false {
                                Button {
                                    toggleAllDeviceSources()
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: isAllDeviceSourcesSelected ? "checkmark" : "")
                                            .frame(width: 12, alignment: .leading)
                                            .foregroundStyle(Color.accentColor)
                                        Text(AppLocalization.string(.allDeviceSources, languageID: interfaceLanguageID))
                                            .font(.callout)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                            }

                            if internalSources.isEmpty == false || deviceSources.isEmpty == false {
                                Divider()
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 2)
                            }

                            ForEach(sources) { source in
                                Button {
                                    toggle(source.id)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: selection.contains(source.id) ? "checkmark" : "")
                                            .frame(width: 12, alignment: .leading)
                                            .foregroundStyle(Color.accentColor)
                                        Text("\(source.category.displayName(in: interfaceLanguageID)) · \(source.name)")
                                            .font(.callout)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .frame(width: 320, height: min(max(CGFloat(sources.count) * 34, 120), 280))
                }

                Divider()

                HStack {
                    Spacer()
                    Button(AppLocalization.string(.done, languageID: interfaceLanguageID)) {
                        isPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        }
        .fixedSize(horizontal: false, vertical: false)
    }

    private var menuTitle: String {
        let selected = sources.filter { selection.contains($0.id) }
        switch selected.count {
        case 0:
            return emptyTitle
        case 1:
            return selected[0].name
        default:
            if isAllSourcesSelected {
                return AppLocalization.string(.allSources, languageID: interfaceLanguageID)
            }
            return AppLocalization.multipleSourcesText(count: selected.count, languageID: interfaceLanguageID)
        }
    }

    private func toggleAllInternalSources() {
        if isAllInternalSourcesSelected {
            selection.subtract(internalSourceIDs)
        } else {
            selection.formUnion(internalSourceIDs)
        }
    }

    private func toggleAllDeviceSources() {
        if isAllDeviceSourcesSelected {
            selection.subtract(deviceSourceIDs)
        } else {
            selection.formUnion(deviceSourceIDs)
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }
}

struct SubtitleModeMenuPicker: View {
    let interfaceLanguageID: String
    let showsDetail: Bool
    @Binding var selection: SubtitleMode

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(SubtitleMode.allCases, id: \.self) { mode in
                if showsDetail {
                    VStack(alignment: .leading) {
                        Text(mode.displayName(in: interfaceLanguageID))
                        Text(mode.detail(in: interfaceLanguageID))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(mode)
                } else {
                    Text(mode.displayName(in: interfaceLanguageID)).tag(mode)
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }
}

struct SubtitleDisplayModeMenuPicker: View {
    let interfaceLanguageID: String
    @Binding var selection: SubtitleDisplayMode

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(SubtitleDisplayMode.allCases, id: \.self) { mode in
                Text(mode.displayName(in: interfaceLanguageID)).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }
}

struct CaptionLayoutMenuPicker: View {
    let interfaceLanguageID: String
    @Binding var selection: OverlayCaptionLayout

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(OverlayCaptionLayout.allCases, id: \.self) { layout in
                Text(layout.displayName(in: interfaceLanguageID)).tag(layout)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel(AppLocalization.string(.captionLayout, languageID: interfaceLanguageID))
    }
}

struct SecondaryRefreshButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: action) {
                Label(title, systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

struct LanguageResourcesFooter: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SecondaryRefreshButton(
            title: model.localized(.refreshLanguageResources),
            action: model.refreshLanguageResources
        )

        if !model.languageResourceStatuses.isEmpty {
            LanguageResourceStatusListView(statuses: model.languageResourceStatuses)
        }
    }
}

struct LanguageResourceStatusListView: View {
    let statuses: [LanguageResourceStatus]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(statuses) { status in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(status.title)
                            .font(.caption.weight(.semibold))
                        Spacer()
                        if let progress = status.progress, status.isError == false {
                            Text("\(Int((progress * 100).rounded()))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    if status.isError {
                        Text(status.detail)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if let progress = status.progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                        Text(status.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                        Text(status.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

extension AppModel {
    var selectedSourcesBinding: Binding<Set<String>> {
        Binding(
            get: { self.selectedSourceIDs },
            set: { self.selectedSourceIDs = $0 }
        )
    }

    var selectedSourceOptionalBinding: Binding<String?> {
        Binding(
            get: { self.selectedSourceID },
            set: { self.selectedSourceID = $0 }
        )
    }

    var inputLanguageSelectionBinding: Binding<String> {
        Binding(
            get: { self.inputLanguageID },
            set: {
                guard self.isLanguagePairLocked == false else { return }
                self.inputLanguageID = self.supportedSpeechInputLanguageID($0)
            }
        )
    }

    var outputLanguageSelectionBinding: Binding<String> {
        Binding(
            get: { self.outputLanguageID },
            set: {
                guard self.isLanguagePairLocked == false else { return }
                self.outputLanguageID = $0
            }
        )
    }

    var subtitleModeSelectionBinding: Binding<SubtitleMode> {
        Binding(
            get: { self.subtitleMode },
            set: { self.subtitleMode = $0 }
        )
    }

    var subtitleDisplayModeSelectionBinding: Binding<SubtitleDisplayMode> {
        Binding(
            get: { self.subtitleDisplayMode },
            set: { self.subtitleDisplayMode = $0 }
        )
    }

    var overlayCaptionLayoutSelectionBinding: Binding<OverlayCaptionLayout> {
        Binding(
            get: { self.overlayStyle.captionLayout },
            set: { layout in self.updateOverlayStyle { $0.captionLayout = layout } }
        )
    }

    var interfaceLanguageSelectionBinding: Binding<String> {
        Binding(
            get: { self.interfaceLanguageID },
            set: { self.interfaceLanguageID = $0 }
        )
    }
}
