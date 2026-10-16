import CoreGraphics
import Foundation

/// Where design C puts the headline block, the band and the Details pane, as numbers.
///
/// At the board's 1100 x 720 every value is exactly the board's. In another window size everything scales together
/// (never below 0.66 or above 1.25 of the board) and the vertical positions keep their distance from the edge they
/// belong to, so nothing overlaps and the band keeps to the text column. The views only read these numbers.
public struct HeroLayout: Equatable, Sendable {
    public enum Screen: Sendable {
        case rest
        case cleaning
        case done
        case empty
        /// Scanning and errors, which the boards do not draw, use the empty screen's frame.
        case message
    }

    /// The pane: 452 wide, 8 from the right, top and bottom edges.
    public static let paneWidth = 452.0
    public static let paneInset = 8.0
    /// Where the content of either face of the pane starts: under the title and the List | Map switch.
    public static let paneContentTop = 78.0
    /// The map: 18 pt of the pane on each side, and under it 16 pt, the caption's 40 and 50 to breathe in.
    public static let mapSideInset = 18.0
    public static let mapBelow = 106.0
    public static let mapMinimumHeight = 120.0
    /// How far the band rises while the map is open: it is thicker, and has a bracket and a caption under it.
    public static let bandRise = 16.0
    public static let minimumWidth = 820.0
    public static let minimumHeight = 560.0

    private static let boardWidth = 1100.0
    private static let boardHeight = 720.0

    public let scale: Double
    /// Left edge and top of the headline block.
    public let leading: Double
    public let top: Double
    public let numberSize: Double
    public let unitSize: Double
    public let numberGap: Double
    public let phraseSize: Double
    public let bodySize: Double
    public let bodyLineHeight: Double
    public let bodyMaxWidth: Double
    public let pillHeight: Double
    public let pillPadding: Double
    public let pillFontSize: Double
    /// The eyebrow line above the number.
    public let eyebrowSize: Double
    /// Gaps between the lines of the block: eyebrow to number, number to phrase, phrase to body, body to the actions.
    public let numberTopGap: Double
    public let phraseTopGap: Double
    public let bodyTopGap: Double
    public let actionsTopGap: Double
    /// Between the pill and what is next to it.
    public let actionsGap: Double
    /// The band's left edge and width, and where its caption row starts, measured from the top of the window.
    public let bandLeading: Double
    public let bandWidth: Double
    public let bandTop: Double
    /// The row of small print above the band (the disk's size, what is free now and after), then 10 pt of air; the band
    /// itself starts `bandLabelsHeight + bandLineGap` under `bandTop`.
    public let bandLabelsHeight: Double
    public let bandLineGap: Double
    /// Where the band itself starts, from the top of the window.
    public var bandLineTop: Double { bandTop + bandLabelsHeight + bandLineGap }

    /// - Parameter mapOpen: the pane is open on the map (only on the rest screen with the pane open): the band is raised
    ///   16 pt to make room for its bracket.
    public init(screen: Screen, detailsOpen: Bool = false, mapOpen: Bool = false, width: Double, height: Double) {
        let s = min(max(min(width / Self.boardWidth, height / Self.boardHeight), 0.66), 1.25)
        scale = s

        let open = screen == .rest && detailsOpen
        leading = (open ? 72 : 112) * s
        top = (screen == .cleaning || screen == .done ? 120 : (open ? 150 : 172)) * s
        numberSize = (open ? 136 : 184) * s
        unitSize = (open ? 42 : 56) * s
        numberGap = (open ? 10 : 14) * s
        phraseSize = (open ? 30 : 36) * s
        bodySize = (open ? 14 : 15) * s
        bodyLineHeight = (open ? 21 : 22) * s
        bodyMaxWidth = (open ? 420 : 470) * s
        pillHeight = (open ? 40 : 44) * s
        pillPadding = (open ? 22 : 24) * s
        pillFontSize = (open ? 14 : 15) * s
        eyebrowSize = 13 * s
        numberTopGap = (open ? 12 : 14) * s
        phraseTopGap = (open ? 10 : 12) * s
        bodyTopGap = (open ? 10 : 12) * s
        actionsTopGap = (open ? 26 : 30) * s
        actionsGap = (open ? 18 : 22) * s

        bandLeading = leading
        if open {
            // The text column ends 48 before the pane (520 of the board's 640).
            let column = width - Self.paneWidth - Self.paneInset - 48 * s
            bandWidth = max(min(520 * s, column - leading), 0)
        } else {
            bandWidth = max(width - 2 * leading, 0)
        }
        let raised = open && mapOpen
        let fromBottom = ((screen == .cleaning || screen == .done ? 80.0 : 108.0) + (raised ? Self.bandRise : 0)) * s
        bandTop = height - fromBottom
        bandLabelsHeight = 15 * s
        bandLineGap = 10 * s
    }

    // MARK: the map

    /// What the pane has under its header, in a window of this height: the window less the pane's margin on both sides
    /// and the header.
    public static func paneContentHeight(windowHeight: Double) -> Double {
        windowHeight - 2 * paneInset - paneContentTop
    }

    /// The map's own size, given what the pane has under its header: the pane's width less its sides, and the height less the
    /// caption's room, never under 120 pt.
    public static func mapArea(paneContentHeight: Double) -> CGSize {
        CGSize(width: paneWidth - 2 * mapSideInset, height: max(paneContentHeight - mapBelow, mapMinimumHeight))
    }

    public static func mapArea(windowHeight: Double) -> CGSize {
        mapArea(paneContentHeight: paneContentHeight(windowHeight: windowHeight))
    }

    /// Where the map's top left is, in the window's coordinates (the pane hugs the right edge).
    public static func mapOrigin(windowWidth: Double) -> CGPoint {
        CGPoint(x: windowWidth - paneInset - paneWidth + mapSideInset, y: paneInset + paneContentTop)
    }
}

/// The name of the volume cmm cleans, as the person knows it: "Macintosh HD", not `/System/Volumes/Data`.
public enum VolumeName {
    /// - Parameter resolve: asks the system for a volume's name; replaceable so the logic is tested without a disk.
    public static func display(forVolume path: String, resolve: (String) -> String? = systemName) -> String {
        // cmm reads the free space of the Data volume, the writable half of the startup volume, which Finder shows as
        // the startup volume under the startup volume's name.
        let asked = path == "/System/Volumes/Data" ? "/" : path
        return resolve(asked) ?? ""
    }

    /// The localized name the system gives the volume mounted at `path`, or nil.
    public static func systemName(forPath path: String) -> String? {
        let name = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }
}
