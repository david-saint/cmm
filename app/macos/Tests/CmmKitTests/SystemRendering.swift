import AppKit
import SwiftUI
import XCTest
@testable import Cmm
@testable import CmmKit

/// Drawing the system side's views offscreen, the way `AppViewsTests` draws the window: in a window of their own, in light or
/// dark, with Increase Contrast standing in through the views' own environment value. With `CMM_SNAPSHOT_DIR` set, every picture
/// is kept there as a PNG, so it can be laid next to its board.
@MainActor
enum SystemRendering {
    static var folder: URL? {
        guard let path = ProcessInfo.processInfo.environment["CMM_SNAPSHOT_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func label(_ appearance: NSAppearance.Name, increasedContrast: Bool = false) -> String {
        (appearance == .darkAqua ? "dark" : "light") + (increasedContrast ? "-contrast" : "")
    }

    static func render<V: View>(
        _ view: V, size: CGSize, appearance: NSAppearance.Name, increasedContrast: Bool = false, name: String? = nil
    ) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let hosting = NSHostingView(
            rootView: view
                .environment(\.cmmIncreasedContrast, increasedContrast)
                .environment(\.cmm, AppViewsTests.env)
                .frame(width: size.width, height: size.height)
        )
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        window.contentView = nil
        if let name { try save(bitmap, as: "\(name)-\(label(appearance, increasedContrast: increasedContrast))") }
        return bitmap
    }

    static func save(_ bitmap: NSBitmapImageRep, as name: String) throws {
        guard let folder, let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try png.write(to: folder.appendingPathComponent("\(name).png"))
    }

    /// Several pictures side by side, top aligned, on the colour of the first one's top left corner.
    static func strip(_ bitmaps: [NSBitmapImageRep], gap: Int = 0) throws -> NSBitmapImageRep {
        let width = bitmaps.map(\.pixelsWide).reduce(0, +) + gap * max(bitmaps.count - 1, 0)
        let height = bitmaps.map(\.pixelsHigh).max() ?? 0
        let strip = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: strip))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        (bitmaps.first?.colorAt(x: 0, y: 0) ?? .white).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        var x = 0
        for bitmap in bitmaps {
            bitmap.draw(in: NSRect(x: x, y: height - bitmap.pixelsHigh, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
            x += bitmap.pixelsWide + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        return strip
    }

    /// Mean brightness (0 black ... 1 white) over a grid of pixels.
    static func brightness(_ bitmap: NSBitmapImageRep) -> Double {
        var total = 0.0
        var count = 0.0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 6) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 6) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                total += 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
                count += 1
            }
        }
        return count == 0 ? 0 : total / count
    }

    /// How many distinct colours a grid of pixels has; a blank render has one.
    static func distinctColors(_ bitmap: NSBitmapImageRep) -> Int {
        var seen = Set<String>()
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                seen.insert(String(format: "%.2f-%.2f-%.2f", c.redComponent, c.greenComponent, c.blueComponent))
            }
        }
        return seen.count
    }

    /// Whether any pixel of a region (top-left origin, in points of a 1x bitmap) is close to `color`. The colour is first put
    /// into the bitmap's own colour space (an offscreen window draws in the display's), so the two are compared like for like.
    static func contains(_ bitmap: NSBitmapImageRep, color: RGBA, in rect: CGRect, tolerance: Double = 0.06) -> Bool {
        guard let target = NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1).usingColorSpace(bitmap.colorSpace) else {
            return false
        }
        for x in Int(rect.minX)..<min(Int(rect.maxX), bitmap.pixelsWide) {
            for y in Int(rect.minY)..<min(Int(rect.maxY), bitmap.pixelsHigh) {
                guard let c = bitmap.colorAt(x: x, y: y) else { continue }
                if abs(c.redComponent - target.redComponent) < tolerance, abs(c.greenComponent - target.greenComponent) < tolerance,
                   abs(c.blueComponent - target.blueComponent) < tolerance {
                    return true
                }
            }
        }
        return false
    }
}
