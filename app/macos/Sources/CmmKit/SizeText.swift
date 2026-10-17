import Foundation

/// Sizes the way the design writes them: decimal gigabytes with one decimal ("8.4 GB", and "0.7 GB" for Homebrew's
/// 704 MB), the disk as a whole number ("228 GB"), and megabytes, kilobytes or bytes only for what would otherwise
/// read "0.0 GB". Every figure is the nearest value of the exact byte count; all arithmetic is on integers, so an
/// exact half (8.45 GB) rounds up and nothing depends on floating point.
///
/// (`ByteFormat` keeps its own rules for the places that always want one decimal in any unit.)
public enum SizeText {
    /// A figure and its unit, kept apart because the headline sets them in different sizes.
    public struct Parts: Equatable, Sendable {
        public let value: String
        public let unit: String

        public var text: String { "\(value) \(unit)" }
    }

    /// Below this a size is said in megabytes: it would round to "0.0 GB" or overstate itself as "0.1 GB".
    private static let gigabyteThreshold: Int64 = 95_000_000

    public static func parts(_ bytes: Int64) -> Parts {
        let b = max(bytes, 0)
        if b == 0 { return Parts(value: "0", unit: "GB") }  // zero is zero in any unit; the screens are about GB
        if b < 1_000 { return Parts(value: "\(b)", unit: "B") }
        if b < 1_000_000 {
            let kb = roundedDivision(b, 1_000)
            if kb < 1_000 { return Parts(value: "\(kb)", unit: "KB") }
        }
        if b < gigabyteThreshold {
            return Parts(value: "\(roundedDivision(b, 1_000_000))", unit: "MB")
        }
        let tenthsOfGB = roundedDivision(b, 100_000_000)
        if tenthsOfGB < 10_000 {
            return Parts(value: tenths(tenthsOfGB), unit: "GB")
        }
        return Parts(value: tenths(roundedDivision(b, 100_000_000_000)), unit: "TB")
    }

    public static func string(_ bytes: Int64) -> String {
        parts(bytes).text
    }

    /// The size of the disk: "228 GB", "1 TB", "1.5 TB".
    public static func capacity(_ bytes: Int64) -> String {
        let b = max(bytes, 0)
        if b < 1_000_000_000 { return string(b) }
        let gb = roundedDivision(b, 1_000_000_000)
        if gb < 1_000 { return "\(gb) GB" }
        let tenthsOfTB = roundedDivision(b, 100_000_000_000)
        return tenthsOfTB % 10 == 0 ? "\(tenthsOfTB / 10) TB" : "\(tenths(tenthsOfTB)) TB"
    }

    /// `n / d` rounded to the nearest integer, halves up, without the overflow of adding half first.
    private static func roundedDivision(_ n: Int64, _ d: Int64) -> Int64 {
        n / d + ((n % d) * 2 >= d ? 1 : 0)
    }

    private static func tenths(_ value: Int64) -> String {
        "\(value / 10).\(value % 10)"
    }
}
