import Foundation

/// Turns the bytes cmm writes to stdout into events, however the operating system happens to chop them up:
/// several lines in one read, one line over several reads, a multi-byte character cut in two.
///
/// A line that cannot be understood becomes `.unreadable` and parsing goes on with the next one, so one bad line
/// never hides the rest of a cleanup. Bytes are split on the newline byte before any text decoding, which is what
/// keeps a character that arrives in two pieces intact.
struct NDJSONParser {
    /// A line longer than this is dropped (and reported once) instead of growing the buffer without bound.
    static let maxLineBytes = 1 << 20
    static let previewLength = 200

    private var buffer = Data()
    private var discarding = false

    /// Adds a chunk and returns the events completed by it.
    mutating func feed(_ chunk: Data) -> [ApplyEvent] {
        var events: [ApplyEvent] = []
        var rest = chunk
        while let newline = rest.firstIndex(of: 0x0A) {
            take(rest[rest.startIndex..<newline], endsLine: true, into: &events)
            rest = rest[rest.index(after: newline)...]
        }
        if !rest.isEmpty {
            take(rest, endsLine: false, into: &events)
        }
        return events
    }

    /// Call when the stream has ended: a last line that has no newline is still a line.
    mutating func finish() -> [ApplyEvent] {
        var events: [ApplyEvent] = []
        if !discarding, !buffer.isEmpty {
            handle(buffer, into: &events)
        }
        buffer.removeAll()
        discarding = false
        return events
    }

    private mutating func take(_ piece: Data, endsLine: Bool, into events: inout [ApplyEvent]) {
        if discarding {
            if endsLine { discarding = false }
            return
        }
        if buffer.count + piece.count > Self.maxLineBytes {
            events.append(.unreadable("a line longer than \(Self.maxLineBytes) bytes"))
            buffer.removeAll()
            discarding = !endsLine
            return
        }
        buffer.append(piece)
        if endsLine {
            handle(buffer, into: &events)
            buffer.removeAll(keepingCapacity: true)
        }
    }

    private func handle(_ raw: Data, into events: inout [ApplyEvent]) {
        var line = raw
        while let last = line.last, last == 0x0D || last == 0x20 || last == 0x09 {
            line.removeLast()
        }
        guard !line.isEmpty else { return }
        do {
            if let event = try ApplyEvent.decode(line: line) {
                events.append(event)
            }
        } catch {
            events.append(.unreadable(Self.preview(of: line)))
        }
    }

    private static func preview(of line: Data) -> String {
        let text = String(decoding: line.prefix(previewLength), as: UTF8.self)
        return line.count > previewLength ? text + "…" : text
    }
}
