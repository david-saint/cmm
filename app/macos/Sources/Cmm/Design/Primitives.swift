import CmmKit
import SwiftUI

// The small parts design C is made of: the dotted fill, the round checkmark, the three kinds of button, the glass the
// pane and the card sit on, and the spinner. Sizes and weights are those of the boards.

// MARK: dots

/// Amber dots on a tinted amber ground, on a 4 pt grid: what needs a person's look. The dots stay visible with
/// Increase Contrast (the colours get stronger variants in `Theme`).
struct DottedFill: View {
    var cell: CGFloat = 4
    var radius: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .style(Theme.reviewFill))
            var dots = Path()
            var y = cell / 2
            while y < size.height + cell {
                var x = cell / 2
                while x < size.width + cell {
                    dots.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    x += cell
                }
                y += cell
            }
            context.fill(dots, with: .style(Theme.review))
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

// MARK: checkmarks

/// The tick of the boards (`M2 5.3l2 2 4-4.6` in a 10-unit box).
struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.53))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.minY + rect.height * 0.73))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.8, y: rect.minY + rect.height * 0.27))
        return path
    }
}

/// A round checkbox: a ring when off, a green disc with a tick when on, with a dash when only part of a group is on.
/// It carries no accessibility of its own; the row it sits in speaks for it.
struct RoundCheck: View {
    let state: TriState
    var size: CGFloat = 18
    /// On a tinted tile the unticked ring sits on a ground of its own, so the tile's colour does not show through it.
    var solidOff = false

    var body: some View {
        ZStack {
            switch state {
            case .off:
                if solidOff { Circle().fill(Theme.badgeOffFill) }
                Circle().strokeBorder(Theme.ring, lineWidth: 1.5)
            case .on:
                Circle().fill(Theme.accent)
                CheckShape()
                    .stroke(Theme.checkInk, style: StrokeStyle(lineWidth: size * 0.105, lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.55, height: size * 0.55)
            case .mixed:
                Circle().fill(Theme.accent)
                Capsule().fill(Theme.checkInk).frame(width: size * 0.42, height: max(1.5, size * 0.1))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: buttons

/// The pill of the boards: solid (the one action of a screen) or soft (everything else), with the heights, paddings and
/// weights each screen uses.
struct PillStyle: ButtonStyle {
    enum Look {
        case solid
        case soft(text: Tone)
    }

    var look: Look = .solid
    var height: CGFloat = 44
    var horizontal: CGFloat = 24
    var leading: CGFloat?
    var fontSize: CGFloat = 15
    var shadowed = true

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, style: self)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let style: PillStyle
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.cmm) private var env

        var body: some View {
            let isSolid: Bool = if case .solid = style.look { true } else { false }
            configuration.label
                .font(Typeface.ui(style.fontSize, .semibold))
                .foregroundStyle(foreground)
                .padding(.leading, style.leading ?? style.horizontal)
                .padding(.trailing, style.horizontal)
                .frame(height: style.height)
                .background {
                    if isSolid {
                        Capsule().fill(Theme.button)
                    } else {
                        Capsule().fill(Theme.soft)
                        Capsule().strokeBorder(Theme.softLine, lineWidth: 0.5)
                    }
                }
                .shadow(color: .black.opacity(isSolid && style.shadowed ? 0.12 : 0), radius: 1, y: 1 * env.shadowDirection)
                .shadow(color: .black.opacity(isSolid && style.shadowed ? 0.26 : 0), radius: 7, y: 6 * env.shadowDirection)
                .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.38)
                .contentShape(Capsule())
        }

        private var foreground: Tone {
            switch style.look {
            case .solid: Theme.buttonText
            case .soft(let text): text
            }
        }
    }
}

/// A text button: the review link, "Rescan" on the done screen.
struct LinkStyle: ButtonStyle {
    var height: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typeface.ui(14, .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 4)
            .frame(height: height)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// The round 30 pt icon buttons at the top right.
struct CircleIconStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        CircleBody(configuration: configuration, active: active)
    }

    private struct CircleBody: View {
        let configuration: ButtonStyleConfiguration
        let active: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(active ? Theme.ink : Theme.ink2)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.hover).opacity(active || hovering || configuration.isPressed ? 1 : 0))
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: glass

/// A shadow as the boards write it: a colour, a blur and how far down it falls.
struct SurfaceShadow {
    let color: Tone
    let radius: CGFloat
    let y: CGFloat
}

/// The surface the Details pane and the confirmation card sit on: Liquid Glass where the system has it, a blurred
/// material where it does not (macOS 14 and 15). Both carry the boards' own 84 to 86 % tint above the glass and under
/// the text, which keeps the text readable over whatever is behind it (the dimmed headline, the band) and gives the
/// surface the boards' colour wherever it is drawn.
struct GlassSurface: ViewModifier {
    let radius: CGFloat
    let tint: Tone
    let shadow: SurfaceShadow
    var nearShadow: SurfaceShadow?
    @Environment(\.cmm) private var env
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack {
                    if #available(macOS 26.0, *) {
                        Color.clear.glassEffect(.regular, in: shape)
                    } else {
                        shape.fill(.regularMaterial)
                    }
                    shape.fill(tint)
                }
            }
            .overlay(shape.strokeBorder(Theme.paneLine, lineWidth: 0.5))
            .background { shadowLayer(shape) }
    }

    private func shadowColor(_ shadow: SurfaceShadow) -> Color {
        shadow.color.rgba(dark: scheme == .dark, increasedContrast: false).color
    }

    /// The shadows, drawn only outside the surface (as CSS draws a box-shadow), so the surface's own translucency
    /// does not pick them up.
    private func shadowLayer(_ shape: RoundedRectangle) -> some View {
        shape.fill(Color.black)
            .shadow(color: shadowColor(shadow), radius: shadow.radius, y: shadow.y * env.shadowDirection)
            .shadow(
                color: nearShadow.map(shadowColor) ?? .clear, radius: nearShadow?.radius ?? 0,
                y: (nearShadow?.y ?? 0) * env.shadowDirection
            )
            .mask {
                Rectangle()
                    .padding(-400)
                    .overlay { shape.fill(Color.black).blendMode(.destinationOut) }
                    .compositingGroup()
            }
    }
}

extension View {
    func glassSurface(radius: CGFloat, tint: Tone, shadow: SurfaceShadow, nearShadow: SurfaceShadow? = nil) -> some View {
        modifier(GlassSurface(radius: radius, tint: tint, shadow: shadow, nearShadow: nearShadow))
    }
}

// MARK: spinner

/// A three-quarter ring that turns once every 1.1 s, as the "Removing" row of the cleaning board. With Reduce Motion
/// it holds still.
struct SpinnerArc: View {
    var size: CGFloat = 15
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let turn = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: max(1.2, size * 0.079), lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
