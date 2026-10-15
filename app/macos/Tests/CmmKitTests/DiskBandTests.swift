import XCTest
@testable import CmmKit

/// The disk band: used / review (dotted) / selected (green) / freed (green outline) / free (outline), proportional
/// to bytes, with a caption and one spoken sentence. The numbers are those of the C boards.
final class DiskBandTests: XCTestCase {
    private let gb: Int64 = 1_000_000_000
    private func g(_ value: Double) -> Int64 { Int64((value * 1_000_000_000).rounded()) }

    // MARK: segments

    func testTheRestBandOfTheBoard() throws {
        let band = try XCTUnwrap(DiskBand(capacity: g(228), free: g(19.8), review: g(9), selected: g(8.4)))
        XCTAssertEqual(band.segments.map(\.kind), [.used, .review, .selected, .free])
        XCTAssertEqual(band.segments.map(\.bytes), [g(190.8), g(9), g(8.4), g(19.8)])
    }

    func testTheCleaningBandOfTheBoard() throws {
        let band = try XCTUnwrap(DiskBand(capacity: g(228), free: g(19.8), review: g(9), selected: g(2.3), freed: g(3.1)))
        XCTAssertEqual(band.segments.map(\.kind), [.used, .review, .selected, .freed, .free])
        XCTAssertEqual(band.segments.map(\.bytes), [g(193.8), g(9), g(2.3), g(3.1), g(19.8)])
    }

    func testTheDoneBandOfTheBoard() throws {
        let band = try XCTUnwrap(DiskBand(capacity: g(228), free: g(19.8), review: g(9), freed: g(5.4)))
        XCTAssertEqual(band.segments.map(\.kind), [.used, .review, .freed, .free])
        XCTAssertEqual(band.segments.map(\.bytes), [g(193.8), g(9), g(5.4), g(19.8)])
    }

    func testTheEmptyBandOfTheBoard() throws {
        let band = try XCTUnwrap(DiskBand(capacity: g(228), free: g(28.2)))
        XCTAssertEqual(band.segments.map(\.kind), [.used, .free])
        XCTAssertEqual(band.segments.map(\.bytes), [g(199.8), g(28.2)])
    }

    func testUnticksAndSkipsStayInUsedBecauseNothingFreesThem() throws {
        // 8.4 GB is safe but only 5.0 GB is ticked: the other 3.4 GB is still on the disk, so it is "used".
        let band = try XCTUnwrap(DiskBand(capacity: g(228), free: g(19.8), review: g(9), selected: g(5.0)))
        XCTAssertEqual(band.segments.first(where: { $0.kind == .used })?.bytes, g(228) - g(19.8) - g(9) - g(5.0))
    }

    func testNothingIsDrawnForNothing() throws {
        let band = try XCTUnwrap(DiskBand(capacity: g(228), free: g(19.8)))
        XCTAssertEqual(band.segments.map(\.kind), [.used, .free], "no review, no selection, no freed")
    }

    func testTheSegmentsAlwaysAddUpToTheCapacity() throws {
        let band = try XCTUnwrap(DiskBand(capacity: g(228), free: g(19.8), review: g(9), selected: g(8.4)))
        XCTAssertEqual(band.segments.reduce(0) { $0 + $1.bytes }, g(228))
        XCTAssertEqual(band.fractions.reduce(0, +), 1, accuracy: 1e-12)
    }

    // MARK: when there is no band

    func testNoCapacityNoBand() {
        XCTAssertNil(DiskBand(capacity: nil, free: g(19.8)))
        XCTAssertNil(DiskBand(capacity: 0, free: g(19.8)))
        XCTAssertNil(DiskBand(capacity: -1, free: g(19.8)))
    }

    func testACapacitySmallerThanTheFreeSpaceIsNotBelieved() {
        XCTAssertNil(DiskBand(capacity: g(10), free: g(19.8)), "free cannot exceed the size of the disk")
        XCTAssertNil(DiskBand.validCapacity(g(10), free: g(19.8)))
        XCTAssertEqual(DiskBand.validCapacity(g(228), free: g(19.8)), g(228))
        XCTAssertNil(DiskBand.validCapacity(nil, free: g(19.8)))
    }

    func testNumbersThatDoNotFitAreScaledNotOverflowed() throws {
        // free + review + selected is more than the disk: used is gone and the rest is drawn in proportion.
        let band = try XCTUnwrap(DiskBand(capacity: g(100), free: g(60), review: g(30), selected: g(30)))
        XCTAssertEqual(band.segments.map(\.kind), [.review, .selected, .free])
        XCTAssertEqual(band.fractions.reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertEqual(band.fractions[2], 0.5, accuracy: 1e-12)
    }

    // MARK: geometry

    func testFramesFollowTheFlexLayoutOfTheBoard() throws {
        let band = try XCTUnwrap(DiskBand(capacity: g(228), free: g(19.8), review: g(9), selected: g(8.4)))
        let frames = band.frames(width: 876, gap: 2)

        XCTAssertEqual(frames.map(\.kind), [.used, .review, .selected, .free])
        XCTAssertEqual(frames[0].x, 0, accuracy: 1e-9)
        for i in 1..<frames.count {
            XCTAssertEqual(frames[i].x, frames[i - 1].x + frames[i - 1].width + 2, accuracy: 1e-9, "a 2 pt gap between segments")
        }
        let last = try XCTUnwrap(frames.last)
        XCTAssertEqual(last.x + last.width, 876, accuracy: 1e-9)
        // 870 pt are shared in proportion: used is 190.8 of 228.
        XCTAssertEqual(frames[0].width, 870 * 190.8 / 228, accuracy: 1e-6)
        XCTAssertEqual(frames[2].width, 870 * 8.4 / 228, accuracy: 1e-6)
    }

    func testATinySegmentKeepsAVisibleWidthAndTheUsedSegmentPaysForIt() throws {
        // 0.1 GB of 228 GB is 0.38 pt on a 876 pt band: it would vanish.
        let band = try XCTUnwrap(DiskBand(capacity: g(228), free: g(19.8), selected: g(0.1)))
        let frames = band.frames(width: 876, gap: 2, minimum: 2)
        let selected = try XCTUnwrap(frames.first { $0.kind == .selected })
        XCTAssertEqual(selected.width, 2, accuracy: 1e-9)
        let last = try XCTUnwrap(frames.last)
        XCTAssertEqual(last.x + last.width, 876, accuracy: 1e-9, "the band still ends where it should")
        let free = try XCTUnwrap(frames.first { $0.kind == .free })
        XCTAssertEqual(free.width, 872 * 19.8 / 228, accuracy: 1e-6, "the free segment is not shrunk to pay for it")
    }

    func testNoFrameIsNegativeOrWiderThanTheBand() throws {
        let band = try XCTUnwrap(DiskBand(capacity: g(228), free: g(19.8), review: g(9), selected: g(8.4), freed: g(3)))
        for width in [0.0, 5, 40, 300, 876, 2000] {
            for frame in band.frames(width: width, gap: 2) {
                XCTAssertGreaterThanOrEqual(frame.width, 0, "width \(width)")
                XCTAssertLessThanOrEqual(frame.x + frame.width, max(width, 0) + 1e-9, "width \(width)")
            }
        }
    }

    func testOnlyTheOuterSegmentsAreRounded() throws {
        let band = try XCTUnwrap(DiskBand(capacity: g(228), free: g(19.8), review: g(9), selected: g(8.4)))
        let frames = band.frames(width: 876, gap: 2)
        XCTAssertEqual(frames.map(\.roundsLeading), [true, false, false, false])
        XCTAssertEqual(frames.map(\.roundsTrailing), [false, false, false, true])
    }
}

final class BandTextTests: XCTestCase {
    private func g(_ value: Double) -> Int64 { Int64((value * 1_000_000_000).rounded()) }

    // MARK: captions

    func testTheRestCaptionOfTheBoard() {
        let caption = BandText.rest(capacity: g(228), free: g(19.8), selected: g(8.4))
        XCTAssertEqual(caption.leading, "228 GB")
        XCTAssertEqual(caption.trailingText, "19.8 GB free now → 28.2 GB after")
        XCTAssertEqual(caption.trailing.filter(\.emphasized).map(\.text), ["28.2 GB"], "only the figure that is the point is bold")
    }

    func testAfterIsFreePlusWhatIsSelected() {
        // Tick less and the figure follows.
        XCTAssertEqual(BandText.rest(capacity: g(228), free: g(19.8), selected: g(5.0)).trailingText, "19.8 GB free now → 24.8 GB after")
        // With the review tier ticked as well.
        XCTAssertEqual(BandText.rest(capacity: g(228), free: g(19.8), selected: g(17.4)).trailingText, "19.8 GB free now → 37.2 GB after")
    }

    func testEachFigureIsTheRoundingOfItsOwnExactValue() {
        // 19.76 + 8.46 = 28.22: the caption says 19.8 and 28.2 (not 28.3, which adding the rounded figures would give).
        let caption = BandText.rest(capacity: g(228), free: g(19.76), selected: g(8.46))
        XCTAssertEqual(caption.trailingText, "19.8 GB free now → 28.2 GB after")
    }

    func testNothingSelectedMeansNoArrow() {
        XCTAssertEqual(BandText.rest(capacity: g(228), free: g(19.8), selected: 0).trailingText, "19.8 GB free now")
    }

    func testWithoutACapacityTheCaptionStaysAndLosesItsLeadingSize() {
        let caption = BandText.rest(capacity: nil, free: g(19.8), selected: g(8.4))
        XCTAssertNil(caption.leading)
        XCTAssertEqual(caption.trailingText, "19.8 GB free now → 28.2 GB after")
        XCTAssertNil(BandText.rest(capacity: g(10), free: g(19.8), selected: 0).leading, "an impossible capacity is not shown either")
    }

    func testTheCleaningCaptionOfTheBoard() {
        let caption = BandText.cleaning(capacity: g(228), freeNow: g(22.9), toGo: g(2.3))
        XCTAssertEqual(caption.leading, "228 GB")
        XCTAssertEqual(caption.trailingText, "22.9 GB free now · 2.3 GB still to go")
        XCTAssertEqual(caption.trailing.filter(\.emphasized).map(\.text), ["22.9 GB"])
        XCTAssertEqual(BandText.cleaning(capacity: g(228), freeNow: g(25.2), toGo: 0).trailingText, "25.2 GB free now")
    }

    func testTheDoneCaptionOfTheBoard() {
        let caption = BandText.done(capacity: g(228), freeBefore: g(19.8), freeAfter: g(25.2))
        XCTAssertEqual(caption.trailingText, "19.8 GB → 25.2 GB free")
        XCTAssertEqual(caption.trailing.filter(\.emphasized).map(\.text), ["25.2 GB"])
    }

    func testTheEmptyCaptionOfTheBoard() {
        let caption = BandText.empty(capacity: g(228), free: g(28.2))
        XCTAssertEqual(caption.leading, "228 GB")
        XCTAssertEqual(caption.trailingText, "28.2 GB free")
    }

    // MARK: the sentence VoiceOver reads for the band

    func testTheRestSentence() {
        XCTAssertEqual(
            BandText.restSentence(capacity: g(228), free: g(19.8), selected: g(8.4), safeTotal: g(8.4), reviewUnselected: g(9)),
            "Disk 228 GB: 19.8 GB free, 8.4 GB safe to remove, 9.0 GB needs your review"
        )
    }

    func testTheRestSentenceSaysSelectedWhenSomethingSafeIsUnticked() {
        XCTAssertEqual(
            BandText.restSentence(capacity: g(228), free: g(19.8), selected: g(5.0), safeTotal: g(8.4), reviewUnselected: g(9)),
            "Disk 228 GB: 19.8 GB free, 5.0 GB selected to remove, 9.0 GB needs your review"
        )
    }

    func testTheRestSentenceLeavesOutWhatIsNotThere() {
        XCTAssertEqual(
            BandText.restSentence(capacity: g(228), free: g(19.8), selected: g(8.4), safeTotal: g(8.4), reviewUnselected: 0),
            "Disk 228 GB: 19.8 GB free, 8.4 GB safe to remove"
        )
        XCTAssertEqual(
            BandText.restSentence(capacity: nil, free: g(19.8), selected: g(8.4), safeTotal: g(8.4), reviewUnselected: g(9)),
            "19.8 GB free, 8.4 GB safe to remove, 9.0 GB needs your review"
        )
        XCTAssertEqual(
            BandText.restSentence(capacity: g(228), free: g(19.8), selected: 0, safeTotal: g(8.4), reviewUnselected: 0),
            "Disk 228 GB: 19.8 GB free"
        )
    }

    func testTheOtherSentences() {
        XCTAssertEqual(BandText.cleaningSentence(capacity: g(228), freeNow: g(22.9), toGo: g(2.3)),
                       "Disk 228 GB: 22.9 GB free, 2.3 GB still to go")
        XCTAssertEqual(BandText.doneSentence(capacity: g(228), freeAfter: g(25.2), freed: g(5.4)),
                       "Disk 228 GB: 25.2 GB free, 5.4 GB freed")
        XCTAssertEqual(BandText.emptySentence(capacity: g(228), free: g(28.2)), "Disk 228 GB: 28.2 GB free")
        XCTAssertEqual(BandText.emptySentence(capacity: nil, free: g(28.2)), "28.2 GB free")
    }
}
