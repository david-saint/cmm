import AppKit
import CmmKit
import SwiftUI

/// The menu bar item itself (the board `C-MenuBar-States`, "Icon + number"): the drive glyph and the free space, with an amber dot
/// between them under 10 GB. VoiceOver reads "8.1 GB free, low on space", so the dot is never the only signal.
///
/// It is one image and one text, which is what a menu bar item is made of: the glyph is the system's template image (so the menu
/// bar tints it), and when the dot is there, glyph and dot are drawn together, at the moment the menu bar draws them, in the menu
/// bar's own ink and the boards' amber.
struct MenuBarLabel: View {
    let item: MenuBarItem

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: MenuBarGlyph.image(low: item.isLow))
            if let title = item.title {
                Text(title).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
    }
}

/// The drive glyph, alone or with the amber dot.
enum MenuBarGlyph {
    /// The glyph's size in the menu bar, and the dot's.
    static let pointSize: CGFloat = 13
    static let dot: CGFloat = 6
    static let gap: CGFloat = 4

    static func image(low: Bool) -> NSImage {
        guard low else {
            let glyph = glyph()
            glyph.isTemplate = true
            return glyph
        }
        let glyphSize = glyph().size
        let size = NSSize(width: glyphSize.width + gap + dot, height: max(glyphSize.height, dot))
        let image = NSImage(size: size, flipped: false) { rect in
            // Drawn when the menu bar draws it, so the ink and the amber are those of the menu bar's look at that moment.
            let look = NSAppearance.currentDrawing().bestMatch(
                from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]
            )
            let dark = look == .darkAqua || look == .accessibilityHighContrastDarkAqua
            let strong = look == .accessibilityHighContrastAqua || look == .accessibilityHighContrastDarkAqua
            let glyph = MenuBarGlyph.glyph()
            let glyphRect = NSRect(x: 0, y: (rect.height - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height)
            glyph.draw(in: glyphRect)
            NSColor.labelColor.set()
            glyphRect.fill(using: .sourceAtop)  // the glyph's shape in the menu bar's ink
            Theme.low.rgba(dark: dark, increasedContrast: strong).nsColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: glyph.size.width + gap, y: (rect.height - dot) / 2, width: dot, height: dot)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The system's drive symbol at the menu bar's size.
    private static func glyph() -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        return NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            ?? NSImage(size: NSSize(width: pointSize * 1.3, height: pointSize))
    }
}

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}
