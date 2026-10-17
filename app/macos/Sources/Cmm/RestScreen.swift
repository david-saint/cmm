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
        let mapOpen = window.mapOpen
        let motion = MotionStyle.resolve(reduceMotion: reduceMotion)
        let layout = HeroLayout(screen: .rest, detailsOpen: open, mapOpen: mapOpen, width: size.width, height: size.height)
        let copy = RestCopy(selection: selection, volumeName: env.volumeName(selection.plan))
        // Under the confirmation card only the headline and the bar remain, dimmed; the sentence, the pill and the
        // captions give way to the card, which grew out of the pill.
        let covered = model.confirmation != nil
        // The map as it is, or would be, in this window: the band's slices are its tiles, and the review link opens it
        // on the tile that needs a look.
        let host = selection.plan.host
        let map = MapModel(selection: selection, size: HeroLayout.mapArea(windowHeight: size.height), home: env.home)
        let doorway = BandDoorway(map: map, capacity: host.capacityBytes, free: host.freeBytes, width: layout.bandWidth)
        let flight = window.flight
        let plan = flight.flatMap { scheduled($0, map: map, host: host, size: size) }
        let showMap: () -> Void = {
            withAnimation(motion.animation) { window.openMap(focusing: map.reviewTileID) }
        }

        return ZStack(alignment: .topLeading) {
            RestHero(
                copy: copy, layout: layout, detailsOpen: open, covered: covered,
                clean: { model.requestClean() },
                // "Review 9.0 GB more": the pane on the map, the tile that needs a look under the keyboard
                review: showMap
            )
            .padding(.leading, layout.leading)
            .padding(.top, layout.top)

            BandBlock(
                band: copy.band, caption: copy.caption, sentence: copy.bandSentence, layout: layout,
                insideLine: copy.insideLine, heldLine: open ? nil : copy.heldLine, covered: covered,
                doorway: doorway.map { band in
                    BandBlock.Doorway(
                        band: band, window: window, motion: motion,
                        open: { id in withAnimation(motion.animation) { window.openMap(focusing: id) } },
                        showMap: showMap
                    )
                }
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

            // the slices in the air: over everything, from the moment they leave to the moment the tiles take over
            if let plan, let flight {
                FlightOverlay(plan: plan, startedAt: flight.startedAt, fixedTime: env.flightTime)
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
        }
        .animation(motion.animation, value: open)
        .animation(motion.animation, value: mapOpen)
        .task(id: window.flight?.generation) { await land(plan) }
    }

    /// Where the slices are going between, for the flight that is under way. Unfolding they leave the band as it was before
    /// the pane opened (the narrow one when the pane was open already); folding they go back to the band of a closed pane.
    private func scheduled(_ flight: WindowState.Flight, map: MapModel, host: CmmKit.Host, size: CGSize) -> FlightSchedule? {
        let unfolding = flight.kind == .unfold
        let band = HeroLayout(
            screen: .rest, detailsOpen: unfolding ? flight.paneWasOpen : false, mapOpen: false, width: size.width, height: size.height
        )
        return FlightSchedule(
            direction: unfolding ? .unfold : .fold, map: map, capacity: host.capacityBytes, free: host.freeBytes, band: band,
            enlarged: flight.bandWasMagnified, windowWidth: size.width
        )
    }

    /// When the flight's time is up the tiles take over from the shapes that flew, with a quick crossfade (the two look the
    /// same, so there is nothing to see but the words arriving).
    private func land(_ plan: FlightSchedule?) async {
        guard env.flightTime == nil, let flight = window.flight else { return }
        let remaining = (plan?.duration ?? 0) - Date().timeIntervalSince(flight.startedAt)
        if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
        guard !Task.isCancelled, window.flight?.generation == flight.generation else { return }
        withAnimation(.easeOut(duration: 0.12)) { window.landFlight(flight.generation) }
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

            if copy.body != nil || copy.followsSelection {
                Group {
                    if let body = copy.body {
                        Paragraph(text: body, size: layout.bodySize, lineHeight: layout.bodyLineHeight)
                    } else {
                        Color.clear.frame(height: 0)  // not Color.clear alone, which would take all the room there is
                    }
                }
                // Once the headline follows the ticks, its line may be there or not, one line or two: the pill stays where
                // it is, so the ticking does not move it.
                .frame(
                    maxWidth: layout.bodyMaxWidth, minHeight: copy.followsSelection ? 2 * layout.bodyLineHeight : 0,
                    alignment: .topLeading
                )
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
