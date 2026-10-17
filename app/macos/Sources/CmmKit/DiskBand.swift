import Foundation

/// The disk band: one line, as wide as the window's text column, that shows where the disk stands.
///
///     used (grey) | review (dotted) | selected (green) | freed (green outline) | free (outline)
///
/// Everything is proportional to bytes. What is ticked ("selected") is green because ticking it is what turns it
/// into free space; what is safe but unticked stays in "used", as do skipped and failed items after a clean,
/// because nothing frees them. Review items stay dotted until someone ticks them. The numbers come from the plan
/// (capacity, free, the tiers) and from cmm's events (freed), never from the app.
public struct DiskBand: Equatable, Sendable {
    public enum Kind: Hashable, Sendable {
        case used
        case review
        case selected
        case freed
        case free
    }

    public struct Segment: Equatable, Sendable {
        public let kind: Kind
        public let bytes: Int64
    }

    /// One segment placed on a line of a given width.
    public struct Frame: Equatable, Sendable {
        public let kind: Kind
        public let x: Double
        public let width: Double
        /// Only the two ends of the band have rounded corners.
        public let roundsLeading: Bool
        public let roundsTrailing: Bool
    }

    public let capacity: Int64
    /// In drawing order. A kind with nothing in it is left out.
    public let segments: [Segment]

    /// The capacity to draw a band with, or nil: without a capacity, or with one smaller than the free space (which
    /// cannot be true), there is no band and the caption carries on alone.
    public static func validCapacity(_ capacity: Int64?, free: Int64) -> Int64? {
        guard let capacity, capacity > 0, capacity >= free else { return nil }
        return capacity
    }

    /// - Parameters:
    ///   - free: free space when the plan was made.
    ///   - review: review-tier bytes that are not selected.
    ///   - selected: bytes that are ticked and still to be cleaned.
    ///   - freed: bytes cmm has reported freed.
    public init?(capacity: Int64?, free: Int64, review: Int64 = 0, selected: Int64 = 0, freed: Int64 = 0) {
        guard let capacity = Self.validCapacity(capacity, free: free) else { return nil }

        let others: [(Kind, Int64)] = [
            (.review, max(review, 0)), (.selected, max(selected, 0)), (.freed, max(freed, 0)), (.free, max(free, 0)),
        ]
        let used = capacity - others.reduce(0) { $0 + $1.1 }

        var segments: [Segment] = []
        if used > 0 { segments.append(Segment(kind: .used, bytes: used)) }
        for (kind, bytes) in others where bytes > 0 {
            segments.append(Segment(kind: kind, bytes: bytes))
        }
        self.capacity = capacity
        self.segments = segments
    }

    /// Each segment's share of the whole, adding up to 1. (When the numbers do not fit the disk, "used" is gone and
    /// the rest are drawn in proportion.)
    public var fractions: [Double] {
        let total = segments.reduce(0) { $0 + $1.bytes }
        guard total > 0 else { return segments.map { _ in 0 } }
        return segments.map { Double($0.bytes) / Double(total) }
    }

    /// Places the segments on a line `width` wide with `gap` between them (the boards use 2 pt). A segment with bytes
    /// in it is never thinner than `minimum`; the widest segment gives up the difference, so the line still ends where
    /// it should. On a line too narrow for the gaps the gaps are dropped.
    public func frames(width: Double, gap: Double = 2, minimum: Double = 2) -> [Frame] {
        let count = segments.count
        guard count > 0 else { return [] }

        let width = max(width, 0)
        let gap = width > gap * Double(count - 1) ? gap : 0
        let available = width - gap * Double(count - 1)

        var widths = fractions.map { $0 * available }
        if available >= minimum * Double(count) {
            var deficit = 0.0
            for index in widths.indices where widths[index] < minimum {
                deficit += minimum - widths[index]
                widths[index] = minimum
            }
            if deficit > 0, let widest = widths.indices.max(by: { widths[$0] < widths[$1] }) {
                widths[widest] = max(minimum, widths[widest] - deficit)
            }
        }

        var x = 0.0
        var frames: [Frame] = []
        for (index, segment) in segments.enumerated() {
            frames.append(Frame(
                kind: segment.kind, x: x, width: widths[index],
                roundsLeading: index == 0, roundsTrailing: index == count - 1
            ))
            x += widths[index] + gap
        }
        return frames
    }
}

/// The words around the band: the caption under it and the one sentence VoiceOver reads for it.
public enum BandText {
    /// A piece of the caption. The piece that is the point is emphasized; an arrow is padded instead of spaced.
    public struct Run: Equatable, Sendable {
        public let text: String
        public let emphasized: Bool
        public let isArrow: Bool

        static func plain(_ text: String) -> Run { Run(text: text, emphasized: false, isArrow: false) }
        static func strong(_ text: String) -> Run { Run(text: text, emphasized: true, isArrow: false) }
        static let arrow = Run(text: "→", emphasized: false, isArrow: true)
    }

    public struct Caption: Equatable, Sendable {
        /// The disk's size ("228 GB"), left of the caption; nil when it is not known.
        public let leading: String?
        public let trailing: [Run]

        /// The trailing part as one string, an arrow set off by spaces.
        public var trailingText: String {
            trailing.map { $0.isArrow ? " \($0.text) " : $0.text }.joined()
        }
    }

    private static func leading(_ capacity: Int64?, free: Int64) -> String? {
        DiskBand.validCapacity(capacity, free: free).map(SizeText.capacity)
    }

    // MARK: captions

    /// `228 GB ... 19.8 GB free now → 28.2 GB after` (the arrow only when something is selected).
    public static func rest(capacity: Int64?, free: Int64, selected: Int64) -> Caption {
        let leading = leading(capacity, free: free)
        guard selected > 0 else {
            return Caption(leading: leading, trailing: [.plain("\(SizeText.string(free)) free now")])
        }
        return Caption(leading: leading, trailing: [
            .plain("\(SizeText.string(free)) free now"), .arrow, .strong(SizeText.string(free + selected)), .plain(" after"),
        ])
    }

    /// `22.9 GB free now · 2.3 GB still to go`
    public static func cleaning(capacity: Int64?, freeNow: Int64, toGo: Int64) -> Caption {
        let tail = toGo > 0 ? " free now · \(SizeText.string(toGo)) still to go" : " free now"
        return Caption(
            leading: leading(capacity, free: freeNow),
            trailing: [.strong(SizeText.string(freeNow)), .plain(tail)]
        )
    }

    /// `19.8 GB → 25.2 GB free`
    public static func done(capacity: Int64?, freeBefore: Int64, freeAfter: Int64) -> Caption {
        Caption(
            leading: leading(capacity, free: max(freeBefore, freeAfter)),
            trailing: [.plain(SizeText.string(freeBefore)), .arrow, .strong(SizeText.string(freeAfter)), .plain(" free")]
        )
    }

    /// `28.2 GB free`
    public static func empty(capacity: Int64?, free: Int64) -> Caption {
        Caption(leading: leading(capacity, free: free), trailing: [.strong(SizeText.string(free)), .plain(" free")])
    }

    // MARK: what VoiceOver reads (the band is one element)

    /// "Disk 228 GB: 19.8 GB free, 8.4 GB safe to remove, 9.0 GB needs your review". `selected` is what the disk gets
    /// back; what is ticked but freed inside another program's storage is said last, as such.
    public static func restSentence(
        capacity: Int64?, free: Int64, selected: Int64, safeTotal: Int64, reviewUnselected: Int64,
        inside: [InsideBytes] = []
    ) -> String {
        var parts = ["\(SizeText.string(free)) free"]
        if selected > 0 {
            parts.append("\(SizeText.string(selected)) \(selected == safeTotal ? "safe to remove" : "selected to remove")")
        }
        if reviewUnselected > 0 {
            parts.append("\(SizeText.string(reviewUnselected)) needs your review")
        }
        if let spoken = Inside.spoken(inside) {
            parts.append(spoken)
        }
        return sentence(capacity: capacity, free: free, parts: parts)
    }

    /// "Disk 228 GB: 22.9 GB free, 2.3 GB still to go"
    public static func cleaningSentence(capacity: Int64?, freeNow: Int64, toGo: Int64) -> String {
        var parts = ["\(SizeText.string(freeNow)) free"]
        if toGo > 0 { parts.append("\(SizeText.string(toGo)) still to go") }
        return sentence(capacity: capacity, free: freeNow, parts: parts)
    }

    /// "Disk 228 GB: 25.2 GB free, 5.4 GB freed"
    public static func doneSentence(capacity: Int64?, freeAfter: Int64, freed: Int64) -> String {
        sentence(capacity: capacity, free: freeAfter, parts: ["\(SizeText.string(freeAfter)) free", "\(SizeText.string(freed)) freed"])
    }

    /// "Disk 228 GB: 28.2 GB free"
    public static func emptySentence(capacity: Int64?, free: Int64) -> String {
        sentence(capacity: capacity, free: free, parts: ["\(SizeText.string(free)) free"])
    }

    private static func sentence(capacity: Int64?, free: Int64, parts: [String]) -> String {
        let body = parts.joined(separator: ", ")
        guard let size = leading(capacity, free: free) else { return body }
        return "Disk \(size): \(body)"
    }
}
