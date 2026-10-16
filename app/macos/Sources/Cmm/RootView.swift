import CmmKit
import SwiftUI

/// The window's content: one screen per state of the model, and, when the person has asked to clean, the confirmation
/// card on top of the rest screen.
///
/// While the card is up the screen behind it is dimmed to the boards' 28 %, disabled and hidden from VoiceOver. That is
/// the focus trap: nothing but the card can be reached by the keyboard or the pointer. Cancel and Esc cancel (a
/// confirmation that is cancelled runs nothing); Delete is the only thing that ends in `AppModel.confirmClean`.
struct RootView: View {
    let model: AppModel
    let window: WindowState
    var env = ViewEnvironment()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pillFrame: CGRect = .zero
    @State private var cardSize = ConfirmCard.size

    var body: some View {
        let motion = MotionStyle.resolve(reduceMotion: reduceMotion)
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.background).ignoresSafeArea()

                screen
                    .opacity(model.confirmation == nil ? 1 : 0.28)
                    .disabled(model.confirmation != nil)
                    .accessibilityHidden(model.confirmation != nil)

                // Esc. It is a key equivalent, so it works whether or not any view holds the keyboard focus: on a Mac
                // without Full Keyboard Access a button cannot take the focus, `onExitCommand` only fires for a
                // focused view, and Esc then reached nothing (found by pressing it in the running window). It is
                // outside the dimmed screen, so the card does not disable it, and it only ever cancels or closes.
                Button("Close") {
                    window.escape(confirmationOpen: model.confirmation != nil, cancelConfirmation: { model.cancelClean() })
                }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)

                if let confirmation = model.confirmation {
                    let placement = CardPlacement(pill: pillFrame, card: cardSize, window: geometry.size)
                    ConfirmCard(
                        confirmation: confirmation,
                        cancel: { model.cancelClean() },
                        delete: { Task { await model.confirmClean(confirmation) } }
                    )
                    .offset(x: placement.origin.x, y: placement.origin.y)
                    .transition(
                        motion.growsCard
                            ? .scale(scale: 0.4, anchor: UnitPoint(x: placement.anchor.x, y: placement.anchor.y)).combined(with: .opacity)
                            : .opacity
                    )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        // The window has no title bar, so its content starts at the very top: the boards' numbers are measured from the
        // window's corner, and the title bar's strip must not push them down or shrink the layout.
        .ignoresSafeArea()
        .coordinateSpace(name: "window")
        .onPreferenceChange(PillFrameKey.self) { pillFrame = $0 }
        .onPreferenceChange(CardSizeKey.self) { if $0.height > 0 { cardSize = $0 } }
        .onChange(of: window.face) { _, face in FacePreference.save(face) }
        // Reduce Motion: the band's slices do not fly, the pane fades in place
        .onChange(of: reduceMotion, initial: true) { _, reduce in window.flightsEnabled = MotionStyle.resolve(reduceMotion: reduce).flies }
        .animation(motion.animation, value: model.confirmation != nil)
        .animation(.easeInOut(duration: 0.25), value: model.phase)
        .environment(\.cmm, env)
    }

    @ViewBuilder private var screen: some View {
        switch model.phase {
        case .idle, .scanning: ScanningScreen()
        case .ready: RestScreen(model: model, window: window)
        case .empty: EmptyScreen(model: model)
        case .cleaning: CleaningScreen(model: model)
        case .done: DoneScreen(model: model)
        case .failed: ErrorScreen(model: model)
        }
    }
}
