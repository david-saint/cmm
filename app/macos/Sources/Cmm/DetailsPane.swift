import CmmKit
import SwiftUI

/// The glass pane that slides in from the right (452 pt): what is safe to remove, what needs a look and what was held
/// back, with every group opening to its items. It only draws `DetailsModel` and forwards ticks to `AppModel`.
struct DetailsPane: View {
    let model: AppModel
    let selection: SelectionModel
    let window: WindowState
    let close: () -> Void
    @Environment(\.cmm) private var env
    @FocusState private var listFocused: Bool

    var body: some View {
        let details = DetailsModel(selection: selection, expanded: window.expanded, home: env.home)
        VStack(spacing: 0) {
            PaneHeader(model: model, window: window)
            DetailsList(model: model, selection: selection, details: details, window: window, listFocused: $listFocused)
        }
        .frame(width: HeroLayout.paneWidth)
        .frame(maxHeight: .infinity)
        .glassSurface(radius: 16, tint: Theme.paneTint, shadow: Theme.paneShadow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Details")
    }
}

/// "Details" with Rescan and Hide details at the right. `accessory` is the room under the title that a List | Map
/// switch will take later; it is empty now, and the list simply starts below it.
struct PaneHeader<Accessory: View>: View {
    let model: AppModel
    let window: WindowState
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Text("Details")
                    .font(Typeface.ui(14, .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.leading, 18)
                    .padding(.top, 16)
                    .accessibilityAddTraits(.isHeader)
                HeaderButtons(model: model, window: window, detailsOpen: true)
                    .padding(.top, 8)
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
            }
            .frame(height: 50, alignment: .topLeading)
            accessory()
        }
    }
}

extension PaneHeader where Accessory == EmptyView {
    init(model: AppModel, window: WindowState) {
        self.init(model: model, window: window) { EmptyView() }
    }
}

/// The scrolling list. It is one stop for the Tab key; inside it the arrows move between rows, space ticks, and right and
/// left open and close a group (see `DetailsNavigation`).
struct DetailsList: View {
    let model: AppModel
    let selection: SelectionModel
    let details: DetailsModel
    let window: WindowState
    var listFocused: FocusState<Bool>.Binding

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(details.sections) { section in
                        SectionHeaderView(section: section)
                            .id("section:\(section.kind.rawValue)")
                        ForEach(section.rows) { row in
                            rowView(row)
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .focusable()
            .focused(listFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .space, .return, .home, .end]) { press in
                handle(press, proxy: proxy)
            }
            .onChange(of: window.scrollTarget) { _, target in
                scroll(to: target, proxy: proxy)
            }
            .onAppear {
                // The review link opens the pane and asks for a section in one go: scroll once the rows exist.
                DispatchQueue.main.async { scroll(to: window.scrollTarget, proxy: proxy) }
            }
        }
    }

    // MARK: rows

    @ViewBuilder
    private func rowView(_ row: DetailsModel.Row) -> some View {
        let focused = listFocused.wrappedValue && window.focusedRow == row.id
        switch row {
        case .group(let group):
            GroupRowView(
                row: group, isFocused: focused,
                tick: { select(row.id); model.toggle(group.group) },
                expand: { select(row.id); window.toggleExpanded(group.group.id) }
            )
        case .item(let item):
            ItemRowView(row: item, isFocused: focused, tick: { select(row.id); model.toggle(item.item) })
        case .footnote(let note):
            FootnoteView(row: note)
        case .held(let held):
            HeldRowView(row: held)
        }
    }

    private func select(_ id: String) {
        window.focusedRow = id
        listFocused.wrappedValue = true
    }

    private func scroll(to target: DetailsModel.SectionKind?, proxy: ScrollViewProxy) {
        guard let target else { return }
        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo("section:\(target.rawValue)", anchor: .top) }
        window.scrollTarget = nil
    }

    // MARK: keyboard

    private func handle(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        let key: DetailsNavigation.Key
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
        let action = DetailsNavigation.handle(key, focused: window.focusedRow, in: details)
        switch action {
        case .none:
            return .handled
        case .focus(let id):
            window.focusedRow = id
            proxy.scrollTo(id)
        case .toggleTick(let id):
            tick(id)
        case .expand(let id):
            setExpanded(id, true)
        case .collapse(let id):
            setExpanded(id, false)
        }
        return .handled
    }

    private func tick(_ id: String) {
        for row in details.sections.flatMap(\.rows) where row.id == id {
            switch row {
            case .group(let group): model.toggle(group.group)
            case .item(let item): model.toggle(item.item)
            default: break
            }
        }
    }

    private func setExpanded(_ rowID: String, _ open: Bool) {
        for row in details.sections.flatMap(\.rows) where row.id == rowID {
            if case .group(let group) = row { window.setExpanded(group.group.id, open) }
        }
    }
}
