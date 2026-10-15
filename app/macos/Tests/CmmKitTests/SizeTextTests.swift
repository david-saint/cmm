import XCTest
@testable import CmmKit

/// The design writes sizes in decimal gigabytes with one decimal ("8.4 GB", "0.7 GB"), the disk as "228 GB", and
/// falls back to MB/KB/B only for what would otherwise read "0.0 GB". All of it is integer arithmetic on bytes, so
/// an exact half (8.45 GB) always rounds up and no figure depends on floating point.
final class SizeTextTests: XCTestCase {
    private func parts(_ bytes: Int64) -> String {
        let p = SizeText.parts(bytes)
        return "\(p.value)|\(p.unit)"
    }

    func testTheNumbersOfTheBoards() {
        let gb: Int64 = 1_000_000_000
        XCTAssertEqual(parts(8_400_000_000), "8.4|GB")
        XCTAssertEqual(parts(19_800_000_000), "19.8|GB")
        XCTAssertEqual(parts(28_200_000_000), "28.2|GB")
        XCTAssertEqual(parts(9 * gb), "9.0|GB")
        XCTAssertEqual(parts(1_400_000_000), "1.4|GB")
        XCTAssertEqual(parts(700_000_000), "0.7|GB", "the board writes Homebrew's 704 MB as 0.7 GB")
        XCTAssertEqual(parts(300_000_000), "0.3|GB")
        XCTAssertEqual(parts(100_000_000), "0.1|GB")
        XCTAssertEqual(parts(208_200_000_000), "208.2|GB")
    }

    func testStringJoinsValueAndUnit() {
        XCTAssertEqual(SizeText.string(8_400_000_000), "8.4 GB")
        XCTAssertEqual(SizeText.parts(8_400_000_000).text, "8.4 GB")
    }

    func testAnExactHalfRoundsUp() {
        XCTAssertEqual(SizeText.string(8_449_999_999), "8.4 GB")
        XCTAssertEqual(SizeText.string(8_450_000_000), "8.5 GB", "8.45 is a half: floating point would say 8.4")
        XCTAssertEqual(SizeText.string(8_350_000_000), "8.4 GB")
        XCTAssertEqual(SizeText.string(2_445_000_000), "2.4 GB")
        XCTAssertEqual(SizeText.string(2_450_000_000), "2.5 GB")
    }

    func testWhatIsTooSmallForGigabytesIsSaidInMegabytes() {
        XCTAssertEqual(SizeText.string(94_999_999), "95 MB")
        XCTAssertEqual(SizeText.string(95_000_000), "0.1 GB")
        XCTAssertEqual(SizeText.string(52_000_000), "52 MB")
        XCTAssertEqual(SizeText.string(1_000_000), "1 MB")
        XCTAssertEqual(SizeText.string(1_499_999), "1 MB")
        XCTAssertEqual(SizeText.string(1_500_000), "2 MB")
    }

    func testKilobytesAndBytes() {
        XCTAssertEqual(SizeText.string(1), "1 B")
        XCTAssertEqual(SizeText.string(999), "999 B")
        XCTAssertEqual(SizeText.string(1_000), "1 KB")
        XCTAssertEqual(SizeText.string(12_345), "12 KB")
        XCTAssertEqual(SizeText.string(999_499), "999 KB")
        XCTAssertEqual(SizeText.string(999_500), "1 MB", "rounding carries into the next unit, never '1000 KB'")
    }

    func testRoundingCarriesFromGigabytesToTerabytes() {
        XCTAssertEqual(SizeText.string(999_940_000_000), "999.9 GB")
        XCTAssertEqual(SizeText.string(999_950_000_000), "1.0 TB", "never '1000.0 GB'")
        XCTAssertEqual(SizeText.string(1_500_000_000_000), "1.5 TB")
    }

    func testZeroAndNegativeAreZero() {
        XCTAssertEqual(SizeText.string(0), "0 GB", "zero is zero in any unit; the screens are about gigabytes")
        XCTAssertEqual(SizeText.string(-5), "0 GB")
    }

    func testTheLargestPossibleValueDoesNotOverflow() {
        XCTAssertEqual(SizeText.string(Int64.max), "9223372.0 TB")
    }

    // MARK: the disk's size

    func testCapacityIsWholeGigabytes() {
        XCTAssertEqual(SizeText.capacity(228_000_000_000), "228 GB")
        XCTAssertEqual(SizeText.capacity(245_107_195_904), "245 GB")
        XCTAssertEqual(SizeText.capacity(500_107_862_016), "500 GB")
        XCTAssertEqual(SizeText.capacity(250_000_000_000), "250 GB")
    }

    func testCapacityInTerabytesDropsAZeroDecimal() {
        XCTAssertEqual(SizeText.capacity(1_000_204_886_016), "1 TB")
        XCTAssertEqual(SizeText.capacity(2_000_398_934_016), "2 TB")
        XCTAssertEqual(SizeText.capacity(1_500_000_000_000), "1.5 TB")
        XCTAssertEqual(SizeText.capacity(999_600_000_000), "1 TB", "999.6 GB rounds to 1000 GB, which is 1 TB")
    }

    func testCapacityOfSomethingTiny() {
        XCTAssertEqual(SizeText.capacity(4_000_000), "4 MB")
    }
}
