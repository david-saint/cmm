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
    /// The band's left edge and width, and where its caption row starts, measured from the top of the window.
    public let bandLeading: Double
    public let bandWidth: Double
    public let bandTop: Double

    public init(screen: Screen, detailsOpen: Bool = false, width: Double, height: Double) {
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

        bandLeading = leading
        if open {
            // The text column ends 48 before the pane (520 of the board's 640).
            let column = width - Self.paneWidth - Self.paneInset - 48 * s
            bandWidth = max(min(520 * s, column - leading), 0)
        } else {
            bandWidth = max(width - 2 * leading, 0)
        }
        let fromBottom = (screen == .cleaning || screen == .done ? 80.0 : 108.0) * s
        bandTop = height - fromBottom
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
