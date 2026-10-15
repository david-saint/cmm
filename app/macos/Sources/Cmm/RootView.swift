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

    var body: some View {
        let motion = MotionStyle.resolve(reduceMotion: reduceMotion)
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.background).ignoresSafeArea()

                screen
                    .opacity(model.confirmation == nil ? 1 : 0.28)
                    .disabled(model.confirmation != nil)
                    .accessibilityHidden(model.confirmation != nil)

                if let confirmation = model.confirmation {
                    let placement = CardPlacement(pill: pillFrame, card: ConfirmCard.size, window: geometry.size)
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
        .animation(motion.animation, value: model.confirmation != nil)
        .animation(.easeInOut(duration: 0.25), value: model.phase)
        .environment(\.cmm, env)
        .onExitCommand {
            window.escape(confirmationOpen: model.confirmation != nil, cancelConfirmation: { model.cancelClean() })
        }
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
