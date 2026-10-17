import Foundation

/// Space that went to another program's own storage instead of the volume, and where ("Docker's disk image").
///
/// A Docker prune frees space inside Docker's disk image, which macOS gives back later or never. So such space is part
/// of what is removed, and never part of the free space afterwards, of the band's green slice or of what a cleaning
/// "freed". The place is whatever cmm says (`frees_inside`), word for word; no program is named in this code.
public struct InsideBytes: Hashable, Sendable {
    public let place: String
    public let bytes: Int64

    public init(place: String, bytes: Int64) {
        self.place = place
        self.bytes = bytes
    }
}

/// The words about space that stays inside, and the arithmetic that keeps places apart.
public enum Inside {
    /// Used when cmm reports inside bytes but names no place.
    static let fallbackPlace = "another program's own storage"

    /// Adds `bytes` to `place`, keeping places in the order they first appear.
    static func add(_ bytes: Int64, to place: String, in list: inout [InsideBytes]) {
        if let index = list.firstIndex(where: { $0.place == place }) {
            list[index] = InsideBytes(place: place, bytes: list[index].bytes + bytes)
        } else {
            list.append(InsideBytes(place: place, bytes: bytes))
        }
    }

    public static func total(_ places: [InsideBytes]) -> Int64 {
        places.reduce(0) { $0 + $1.bytes }
    }

    // MARK: sentences

    /// Under the band at rest, while such items are ticked.
    /// `+ 6.2 GB inside Docker's disk image, not counted above.`
    public static func restLine(_ places: [InsideBytes]) -> String? {
        Phrase(places).map { "+ \($0.whole), not counted above." }
    }

    /// Under the band while cleaning.
    /// `+ 2.1 GB inside Docker's disk image`
    public static func cleaningLine(_ places: [InsideBytes]) -> String? {
        Phrase(places).map { "+ \($0.whole)" }
    }

    /// On the confirmation card: two short sentences, one to a line, so the card does not wrap one in the middle.
    /// `6.2 GB is freed inside Docker's disk image.` / `The disk shows it later, if at all.`
    public static func cardSentence(_ places: [InsideBytes]) -> String? {
        Phrase(places).map { "\($0.size) is freed \($0.where_).\nThe disk shows it later, if at all." }
    }

    /// On the done screen.
    /// `6.2 GB was freed inside Docker's disk image; the disk shows it when that space is given back.`
    public static func doneSentence(_ places: [InsideBytes]) -> String? {
        Phrase(places).map { "\($0.size) was freed \($0.where_); the disk shows it when that space is given back." }
    }

    /// For VoiceOver, in the band's sentence.
    /// `6.2 GB selected inside Docker's disk image, not counted as free space`
    static func spoken(_ places: [InsideBytes]) -> String? {
        Phrase(places).map { "\($0.size) selected \($0.where_), not counted as free space" }
    }

    // MARK: pieces

    /// `6.2 GB inside Docker's disk image`, or `6.2 GB inside X and 1.0 GB inside Y`, in two pieces so a sentence can
    /// put words between the size and the place.
    private struct Phrase {
        /// The first place's size: `6.2 GB`.
        let size: String
        /// `inside Docker's disk image`, or `inside X and 1.0 GB inside Y`.
        let where_: String
        var whole: String { "\(size) \(where_)" }

        init?(_ places: [InsideBytes]) {
            let named = places.filter { $0.bytes > 0 }
            guard let first = named.first else { return nil }
            size = SizeText.string(first.bytes)
            let parts = named.enumerated().map { index, place in
                index == 0 ? "inside \(place.place)" : "\(SizeText.string(place.bytes)) inside \(place.place)"
            }
            where_ = parts.count == 1
                ? parts[0]
                : parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }
}
