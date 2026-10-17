import CmmKit
import SwiftUI

/// The one-time card (the board `C-Optin`): "Keep an eye on your disk?" Turn on switches on the menu bar item, the weekly
/// reminder, the free-space history and Open at login, and is the moment macOS asks about notifications; Not now changes
/// nothing. Either answer puts the card away for good. It sizes itself with the headline beside it.
struct OptInCard: View {
    var scale: Double = 1
    let turnOn: () -> Void
    let notNow: () -> Void

    var body: some View {
        let s = scale
        VStack(alignment: .leading, spacing: 0) {
            Text(OptInCopy.title)
                .font(Typeface.serif(17 * s))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Paragraph(text: OptInCopy.line, size: 13 * s, lineHeight: 19 * s, color: Theme.ink)
                .padding(.top, 4 * s)
            Paragraph(text: OptInCopy.smallPrint, size: 11.5 * s, lineHeight: 16 * s)
                .padding(.top, 8 * s)
            HStack(spacing: 14 * s) {
                Button(action: turnOn) { Text(OptInCopy.turnOn) }
                    .buttonStyle(OptInButtonStyle(filled: true, scale: s))
                    .accessibilityHint("Shows free space in the menu bar, reminds you on Mondays, keeps a free-space history and opens cmm at login")
                Button(action: notNow) { Text(OptInCopy.notNow) }
                    .buttonStyle(OptInButtonStyle(filled: false, scale: s))
                    .accessibilityHint("Changes nothing. This card does not come back")
            }
            .padding(.top, 14 * s)
        }
        .padding(.vertical, 16 * s)
        .padding(.horizontal, 18 * s)
        .frame(width: OptInPlacement.boardWidth * s, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16 * s, style: .continuous).fill(Theme.cardGround))
        .overlay(RoundedRectangle(cornerRadius: 16 * s, style: .continuous).strokeBorder(Theme.cardEdge, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(OptInCopy.title)
    }
}

/// The card's two buttons: Turn on on a soft ground, Not now as quiet words.
struct OptInButtonStyle: ButtonStyle {
    let filled: Bool
    var scale: Double = 1

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.ui(13 * scale, filled ? .semibold : .medium))
            .foregroundStyle(filled ? Theme.ink : Theme.ink2)
            .padding(.horizontal, (filled ? 14 : 2) * scale)
            .frame(height: 28 * scale)
            .background { if filled { Capsule().fill(Theme.cardButton) } }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// Where the window puts the card: over the screen, beside the headline (`OptInPlacement`), while the person has not answered it
/// and the screen is at rest. Without the settings (a window drawn on its own, as in the render tests of the first milestone)
/// there is no card.
struct OptInSlot: View {
    let model: AppModel
    let window: WindowState
    /// Where the rest screen's Clean pill is, in the window (zero when there is none).
    let pill: CGRect
    @Environment(SettingsModel.self) private var settings: SettingsModel?

    var body: some View {
        if let settings, OptInPlacement.isShown(
            optInAnswered: settings.optInAnswered, phase: model.phase, confirmationOpen: model.confirmation != nil,
            detailsOpen: window.detailsOpen
        ) {
            GeometryReader { geometry in
                let placement = OptInPlacement(
                    windowWidth: geometry.size.width, windowHeight: geometry.size.height, pillFrame: model.phase == .ready ? pill : nil
                )
                OptInCard(
                    scale: placement.scale,
                    turnOn: { Task { await settings.turnOnEverything() } },
                    notNow: { settings.declineOptIn() }
                )
                .frame(width: placement.right, height: placement.bottom, alignment: .bottomTrailing)
            }
            .transition(.opacity)
        }
    }
}
