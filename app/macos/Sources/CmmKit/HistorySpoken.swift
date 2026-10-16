import Foundation

// What VoiceOver says for the History list (spec R11): the list is the chart's accessible equivalent, so each week and each
// cleaning reads as one line of words, in the order the eye reads the row, and nothing is said by colour alone.

extension RunRows.Week {
    /// `This week, 5.4 GB freed`
    public var spoken: String { "\(title), \(totalText) freed" }
}

extension RunRows.Row {
    /// `Thu 9 Oct 09:41, 2.2 GB freed, Homebrew old versions, npm cache, 1 failed`: when, what the disk got back, what stopped
    /// it, the groups, what failed and, apart, what went inside another program's storage.
    public var spoken: String {
        ["\(dateText) \(timeText)", freedText, stoppedText, groupsText, failedText, insideText]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

extension RunRows.Item {
    /// `~/Library/Caches/go-build, permission denied, 1.2 GB`
    public var spoken: String { "\(title), \(detail), \(sizeText)" }
}
