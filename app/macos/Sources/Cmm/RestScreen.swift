import CmmKit
import SwiftUI

/// Where the Clean pill is on the screen, so the confirmation card can grow from it.
struct PillFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// "At rest": how much is safe to remove, one pill to remove what is ticked, a link to what needs a look, and the
/// disk band. With the Details open the same words shrink to the left and the pane slides in from the right.
struct RestScreen: View {
    let model: AppModel
    let window: WindowState
    @Environment(\.cmm) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let selection = model.selection {
            GeometryReader { geometry in
                content(selection: selection, size: geometry.size)
            }
        }
    }

    private func content(selection: SelectionModel, size: CGSize) -> some View {
        let open = window.detailsOpen
        let motion = MotionStyle.resolve(reduceMotion: reduceMotion)
        let layout = HeroLayout(screen: .rest, detailsOpen: open, width: size.width, height: size.height)
        let copy = RestCopy(selection: selection, volumeName: env.volumeName(selection.plan))
        // Under the confirmation card only the headline and the bar remain, dimmed; the sentence, the pill and the
        // captions give way to the card, which grew out of the pill.
        let covered = model.confirmation != nil

        return ZStack(alignment: .topLeading) {
            RestHero(
                copy: copy, layout: layout, detailsOpen: open, covered: covered,
                clean: { model.requestClean() },
                review: {
                    // "Review 9.0 GB more": the pane on the map, the tile that needs a look under the keyboard
                    let map = MapModel(selection: selection, size: CGSize(width: 416, height: 520), home: env.home)
                    withAnimation(motion.animation) { window.openMap(focusing: map.reviewTileID) }
                }
            )
            .padding(.leading, layout.leading)
            .padding(.top, layout.top)

            BandBlock(
                band: copy.band, caption: copy.caption, sentence: copy.bandSentence, layout: layout,
                insideLine: copy.insideLine, heldLine: open ? nil : copy.heldLine, covered: covered
            )
            .offset(x: layout.bandLeading, y: layout.bandTop)

            if open {
                DetailsPane(model: model, selection: selection, window: window) {
                    withAnimation(motion.animation) { window.closeDetails() }
                }
                .padding(HeroLayout.paneInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .transition(motion.slidesPane ? .move(edge: .trailing).combined(with: .opacity) : .opacity)
            } else {
                HeaderButtons(model: model, window: window, detailsOpen: false)
                    .opacity(covered ? 0 : 1)
                    .padding(.top, 14)
                    .padding(.trailing, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .animation(motion.animation, value: open)
    }
}

/// The headline block of the rest screen.
struct RestHero: View {
    let copy: RestCopy
    let layout: HeroLayout
    let detailsOpen: Bool
    var covered = false
    let clean: () -> Void
    let review: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeroHeader(layout: layout, eyebrow: copy.eyebrow, number: copy.number, phrase: copy.sentence)

            if let body = copy.body {
                Paragraph(text: body, size: layout.bodySize, lineHeight: layout.bodyLineHeight)
                    .frame(maxWidth: layout.bodyMaxWidth, alignment: .leading)
                    .padding(.top, layout.bodyTopGap)
                    .opacity(covered ? 0 : 1)
            }

            HStack(spacing: layout.actionsGap) {
                Button(action: clean) {
                    Text(copy.pillTitle)
                }
                .buttonStyle(PillStyle(
                    look: .solid, height: layout.pillHeight, horizontal: layout.pillPadding, fontSize: layout.pillFontSize
                ))
                .disabled(!copy.pillEnabled)
                .accessibilityLabel(copy.pillTitle.replacingOccurrences(of: "…", with: ""))
                .accessibilityHint("Opens a confirmation. Nothing is deleted until you confirm.")
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: PillFrameKey.self, value: proxy.frame(in: .named("window")))
                })

                if let link = copy.reviewLink, !detailsOpen {
                    Button(action: review) {
                        HStack(spacing: 8) {
                            Circle().fill(Theme.review).frame(width: 7, height: 7)
                            Text(link).monospacedDigit()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.ink2)
                        }
                    }
                    .buttonStyle(LinkStyle(height: layout.pillHeight))
                    .accessibilityLabel(link)
                    .accessibilityHint("Shows the review items in the details pane")
                } else {
                    Text(copy.tickedText)
                        .font(Typeface.ui(12.5 * layout.scale))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink2)
                }
            }
            .padding(.top, layout.actionsTopGap)
            .opacity(covered ? 0 : 1)
        }
    }
}

/// Rescan and Show details, the two round buttons at the top right (inside the pane's header when it is open).
/// The keyboard shortcuts live in the app's menu (⌘R, ⌘I), so they work wherever the focus is.
struct HeaderButtons: View {
    let model: AppModel
    let window: WindowState
    let detailsOpen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let motion = MotionStyle.resolve(reduceMotion: reduceMotion)
        HStack(spacing: detailsOpen ? 4 : 6) {
            Button {
                Task { await model.scan() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 14.5, weight: .medium))
            }
            .buttonStyle(CircleIconStyle())
            .disabled(model.phase == .scanning || model.phase == .cleaning)
            .help("Rescan (⌘R)")
            .accessibilityLabel("Rescan")

            Button {
                withAnimation(motion.animation) { window.toggleDetails() }
            } label: {
                Image(systemName: "sidebar.trailing").font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(CircleIconStyle(active: detailsOpen))
            .help(detailsOpen ? "Hide details (⌘I)" : "Show details (⌘I)")
            .accessibilityLabel(detailsOpen ? "Hide details" : "Show details")
        }
    }
}
