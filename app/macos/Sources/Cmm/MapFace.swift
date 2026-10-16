import CmmKit
import SwiftUI

/// The map face of the Details pane: everything cmm found as one treemap, a tile per item, sized by bytes, with one
/// line about the tile in focus under it.
///
/// The selection is the list's: a tile ticks and unticks through `AppModel`, so the pill, the band, the card and the list
/// rows all follow, and the other way round. The map is one tab stop with the keyboard inside it (arrows, Space, Return,
/// Home, End), like the list, because on a Mac without Full Keyboard Access a button cannot take the focus; clicking a tile
/// focuses the map and the tile.
struct MapFace: View {
    let model: AppModel
    let selection: SelectionModel
    let window: WindowState
    @Environment(\.cmm) private var env
    /// False behind the confirmation card, which disables the screen: a disabled view that already has the keyboard still gets
    /// its key presses, so the map has to leave them alone itself.
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var mapFocused: Bool

    /// The board: 18 pt of the pane on each side, and under the map 16 pt, then the caption, then room to breathe.
    private static let sideInset = HeroLayout.mapSideInset

    var body: some View {
        GeometryReader { geometry in
            let area = HeroLayout.mapArea(paneContentHeight: geometry.size.height)
            let map = MapModel(selection: selection, size: area, home: env.home)
            VStack(alignment: .leading, spacing: 0) {
                if map.tiles.isEmpty {
                    Text("Nothing on this plan can be ticked here.")
                        .font(Typeface.ui(12.5))
                        .foregroundStyle(Theme.ink2)
                        .frame(width: area.width, height: area.height, alignment: .center)
                } else {
                    tiles(map, area: area)
                    caption(map)
                        .padding(.top, 16)
                }
            }
            .padding(.horizontal, Self.sideInset)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .background { keyEquivalents(map) }
        }
    }

    /// The arrows, Home and End as key equivalents too, so they work whether or not the map has the keyboard: on a Mac
    /// without Full Keyboard Access nothing here takes it until a tile is clicked, and the first arrow pressed then
    /// moves the focus to a tile and gives the map the keyboard, which is what Space and Return need. Space and Return are
    /// not key equivalents: with Full Keyboard Access they belong to whichever button has the focus. These live in this
    /// face only (so the list's keys are the list's), inside the screen the confirmation card disables (so nothing here
    /// is live while the card is up), and do exactly what the keys inside the map do; a key equivalent is tried before
    /// the key reaches a view, so a press is never handled twice.
    private func keyEquivalents(_ map: MapModel) -> some View {
        Group {
            Button("Up") { act(.up, in: map) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("Down") { act(.down, in: map) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("Left") { act(.left, in: map) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("Right") { act(.right, in: map) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("First") { act(.home, in: map) }.keyboardShortcut(.home, modifiers: [])
            Button("Last") { act(.end, in: map) }.keyboardShortcut(.end, modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: the tiles

    private var focusVisible: Bool { mapFocused || env.showsFocusWithoutKeyboard }

    /// The tiles are not there while the band's slices are still flying into them: the shapes in the air are the tiles until
    /// the plan's time is up, and then these take over.
    private var inTheAir: Bool { window.flight?.kind == .unfold }

    private func tiles(_ map: MapModel, area: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            // a click in a gap between tiles still takes the keyboard
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { requestFocus() }
            tileViews(map)
                .opacity(inTheAir ? 0 : 1)
                .allowsHitTesting(!inTheAir)
                // gone at once when the slices leave, back with a quick fade when they land
                .animation(inTheAir ? nil : .easeOut(duration: 0.12), value: inTheAir)
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
        .focusable()
        .focused($mapFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .space, .return, .home, .end]) { press in
            handle(press, in: map)
        }
        .onChange(of: window.mapFocusRequest) { _, _ in requestFocus() }
        .onChange(of: mapFocused) { _, has in window.mapKeyboard = has }
        .onAppear {
            if window.focusedTile != nil { requestFocus() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reclaimable space map")
    }

    private func tileViews(_ map: MapModel) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(map.tiles) { tile in
                let isFocused = focusVisible && window.focusedTile == tile.id
                MapTileView(
                    tile: tile,
                    hovered: window.hoveredTile == tile.id,
                    focused: isFocused,
                    select: {
                        window.focusedTile = tile.id
                        mapFocused = true
                        toggle(tile)
                    },
                    hover: { inside in window.pointer(onTile: tile.id, inside: inside) }
                )
                .offset(x: tile.rect.minX, y: tile.rect.minY)
                .zIndex(isFocused ? 1 : 0)
            }
        }
    }

    private func requestFocus() {
        // after this pass of layout: the map may only just have appeared
        DispatchQueue.main.async { mapFocused = true }
    }

    private func toggle(_ tile: MapTile) {
        switch tile.target {
        case .item(let item): model.toggle(item)
        case .group(let group): model.toggle(group)
        }
    }

    private func handle(_ press: KeyPress, in map: MapModel) -> KeyPress.Result {
        // The arrows carry the numeric-pad and function flags and Home and End the function flag (on a laptop they are Fn with
        // the arrows), so "no modifiers" would drop every real press: only what makes a shortcut is somebody else's.
        guard isEnabled, press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
        let key: MapNavigation.Key
        switch press.key {
        case .upArrow: key = .up
        case .downArrow: key = .down
        case .leftArrow: key = .left
        case .rightArrow: key = .right
        case .space: key = .space
        case .return: key = .return
        case .home: key = .home
        case .end: key = .end
        default: return .ignored
        }
        act(key, in: map)
        return .handled
    }

    private func act(_ key: MapNavigation.Key, in map: MapModel) {
        switch MapNavigation.handle(key, focused: window.focusedTile, in: map) {
        case .none:
            break
        case .focus(let id):
            window.focusedTile = id
            requestFocus()  // so Space, and the keys inside the map, find it from here on
        case .toggle(let id):
            if let tile = map.tile(id: id) { toggle(tile) }
        }
    }

    // MARK: the caption

    /// Two lines about one tile: the one with the keyboard focus, or, when nothing has it, the one under the pointer.
    private func caption(_ map: MapModel) -> some View {
        let subject = MapCaptionRule.subject(
            focused: focusVisible ? window.focusedTile : nil, hovered: window.hoveredTile, in: map
        )
        return VStack(alignment: .leading, spacing: 4) {
            if let tile = subject {
                let caption = tile.caption
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(caption.title).font(Typeface.ui(13, .semibold)).foregroundStyle(Theme.ink)
                    Text(caption.sizeText).font(Typeface.ui(13)).monospacedDigit().foregroundStyle(Theme.ink)
                    HStack(spacing: 5) {
                        Circle().fill(caption.isReview ? Theme.review : Theme.accent).frame(width: 6, height: 6)
                        Text(caption.status).font(Typeface.ui(12)).foregroundStyle(caption.isReview ? Theme.reviewText : Theme.accentLabel)
                    }
                }
                .lineLimit(1)
                .frame(height: 18)
                Text(caption.note)
                    .font(Typeface.ui(11.5))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(width: HeroLayout.paneWidth - 2 * Self.sideInset, height: 40, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(subject.map { "\($0.caption.title), \($0.caption.sizeText), \($0.caption.status). \($0.caption.note)" } ?? "")
        .accessibilityHidden(subject == nil)
    }
}
