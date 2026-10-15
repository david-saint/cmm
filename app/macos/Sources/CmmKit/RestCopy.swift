import Foundation

/// Everything the "at rest" screen says and draws, derived from the plan and from what is ticked:
///
/// - the headline is the **safe** total, whatever is ticked;
/// - the pill and the "N items ticked" line follow **what is ticked**, all of it, because that is what will be removed;
/// - the band and the "after" figure follow what the **disk gets back**: free space now plus the ticked items that do not
///   free their space inside another program's own storage (a Docker prune frees it inside Docker's disk image). What
///   stays inside is said once, quietly, under the band (`insideLine`), and its bytes stay dotted rather than green.
public struct RestCopy: Equatable, Sendable {
    /// `Macintosh HD · 19.8 GB free of 228 GB`
    public let eyebrow: String
    /// The big number: the safe total.
    public let number: SizeText.Parts
    /// `is safe to remove.`
    public let sentence: String
    public let body: String?
    /// `Clean 8.4 GB…`, or `Nothing ticked` (and the button is off).
    public let pillTitle: String
    public let pillEnabled: Bool
    /// `Review 9.0 GB more`; nil when cmm offers nothing for review.
    public let reviewLink: String?
    /// `9 items ticked`
    public let tickedText: String
    public let held: [HeldRow]
    /// `1 held back: unavailable simulators, because Simulator is running`
    public let heldLine: String?
    /// Nil without a believable capacity: no band, the caption stays.
    public let band: DiskBand?
    public let caption: BandText.Caption
    public let bandSentence: String
    /// `+ 6.2 GB inside Docker's disk image, not counted above.` while such items are ticked; nil otherwise.
    public let insideLine: String?

    public init(selection: SelectionModel, volumeName: String) {
        let host = selection.plan.host
        let free = host.freeBytes
        let capacity = DiskBand.validCapacity(host.capacityBytes, free: free)
        let selected = selection.selectedBytes
        let onDisk = selection.selectedVolumeBytes
        let inside = selection.selectedInside
        let reviewUnselected = max(selection.reviewBytes - selection.selectedReviewBytes, 0)

        var freeText = "\(SizeText.string(free)) free"
        if let capacity { freeText += " of \(SizeText.capacity(capacity))" }
        eyebrow = ([volumeName.isEmpty ? nil : volumeName, freeText].compactMap { $0 }).joined(separator: " · ")

        number = SizeText.parts(selection.plannedBytes)
        sentence = "is safe to remove."
        body = HeroBody.text(for: selection)
            ?? (selection.reviewBytes > 0 ? "Nothing regenerable was found. What cmm offers for review is your call." : nil)

        pillTitle = selection.selectedCount == 0 ? "Nothing ticked" : "Clean \(SizeText.string(selected))…"
        pillEnabled = selection.selectedCount > 0
        tickedText = "\(Plural.items(selection.selectedCount)) ticked"

        if selection.reviewBytes == 0 {
            reviewLink = nil
        } else if selection.selectedReviewBytes == 0 {
            reviewLink = "Review \(SizeText.string(selection.reviewBytes)) more"
        } else if reviewUnselected == 0 {
            reviewLink = "Includes \(SizeText.string(selection.reviewBytes)) you reviewed"
        } else {
            reviewLink = "Review \(SizeText.string(reviewUnselected)) more"
        }

        held = DetailsModel.heldRows(selection: selection)
        heldLine = HeldBack.line(for: held)
        band = DiskBand(capacity: capacity, free: free, review: selection.reviewDottedBytes, selected: onDisk)
        caption = BandText.rest(capacity: capacity, free: free, selected: onDisk)
        bandSentence = BandText.restSentence(
            capacity: capacity, free: free, selected: onDisk, safeTotal: selection.plannedBytes,
            reviewUnselected: reviewUnselected, inside: inside
        )
        insideLine = Inside.restLine(inside)
    }
}
