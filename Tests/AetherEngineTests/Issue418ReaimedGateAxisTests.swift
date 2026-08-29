import Testing
import Foundation
@testable import AetherEngine

/// AE#418 (rrgomes): after a restart whose gate re-aimed below its boundary, the clock ran ahead of
/// the picture by the re-aim. Captions about four seconds early on a resume that re-aimed 3.045 s,
/// about eight after restarts that re-aimed 3.1 and 5.0, and a synced host reports the wrong position
/// with them. Lip sync survives, because audio and video sit in the same segment.
///
/// **AVPlayer presents a segment at the position the PLAYLIST gives it, not at the tfdt it carries.**
/// AE#408 shipped the early-opening gate on the opposite assumption and published no offset for that
/// case. `aetherctl play --picture-probe` measures it directly, on a fixture whose picture states its
/// own source time in binary.
///
/// Round 1 (6.43.0) got the offset right and its LIFETIME wrong. It keyed the offset to "the decode
/// run AVPlayer began here" and answered that from the fetch order, treating any request that did not
/// follow its predecessor as a fresh run. The reporter's seek burst falsified it: a fetch out of
/// sequence happens while AVPlayer stays inside the run it is already playing, and the axis was then
/// republished from under a picture that had not moved, which is the pre-fix shape re-entered.
///
/// Round 2 measures what the offset actually does, at re-aims of 0.5, 0.875, 1, 3, 5, 7, 9 and 11 s:
///
/// - It **composes**. AVPlayer places a segment at its advertised start read through the mapping its
///   timeline ALREADY carries, so re-placing an overlong segment adds its offset again. A resume that
///   opened 9 s below its boundary reads `axisErr=-9.000`; a seek that makes AVPlayer fetch that same
///   segment a second time reads `-18.000`, and one that provokes a restart re-aiming 5 s more reads
///   `-14.000`. Round 1 published `0.000` for all three.
/// - It survives a seek unchanged, which is what the reporter's case turns on, **unless it is under a
///   second**: `-0.500` and `-0.875` read `axisErr=0.000` after a seek, `-1.000` and everything above
///   it survive one. AVPlayer discards a sub-second axis and snaps back to the playlist.
///
/// Measured on `tc-cues-lie.mkv` (Cues injected at non-sync positions, 12 s keyframe drought at 43 s),
/// `capErr` being the error a host placing a cue at `sourceTime` would make:
///
/// | case | round 1 | round 2 |
/// | --- | --- | --- |
/// | resume 53, seek to 80 (the reporter's shape) | `-8.983` | `+0.017` |
/// | resume 53, seek to 65 (re-places the anchor) | `-8.983` | `+0.017` |
/// | resume 53, seek to 60 (restart re-aims again) | `-8.983` | `+0.017` |
/// | resume 10, burst (sub-second, snaps) | `-0.008` | `+0.017` |
struct Issue418ReaimedGateAxisTests {

    // The reporter's `#65 ledger`, in the millisecond time base its lines are printed in.
    // Each row is (advertised boundary, where the gate actually opened, the drift he tabulated).
    private static let ledger: [(boundary: Int64, gateOpenedAt: Int64, drift: Int64)] = [
        (352_936, 349_891, -3_045),   // session 1 + 2, the resume at 354.0
        (676_134, 662_078, -14_056),  // session 1, seek to 682.0, re-aimed 4s, 8s, 12s, 16s
        (972_847, 969_802, -3_045),   // session 1, seek to 992.0
        (1_084_375, 1_083_332, -1_043), // session 1, seek to 1102.0
        (512_053, 508_925, -3_128),   // session 2, seek to 519.3
        (684_809, 679_762, -5_047),   // session 2, seek to 689.3
        (604_521, 604_896, 375)       // session 2, seek to 609.3: a LATE opening, the pinned case
    ]

    // MARK: - The offset is measured against the advertised start

    @Test("every re-aimed restart in the report publishes its own drift, not zero")
    func ledgerRowsPublishTheirDrift() {
        for row in Self.ledger {
            let published = HLSSegmentProducer.presentedShiftPts(
                actualFirstDts: row.gateOpenedAt, desiredTfdtPts: row.boundary)
            #expect(published == row.drift,
                    "boundary \(row.boundary) opened at \(row.gateOpenedAt)")
        }
    }

    @Test("a gate that opened early publishes a negative shift, which is what was missing")
    func earlyGatePublishesNegative() {
        // The harness case: boundary 52.000 s, gate re-aimed and opened at 43.000 s.
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstDts: 43_000, desiredTfdtPts: 52_000) == -9_000)
    }

    @Test("a gate that opened exactly on its boundary publishes nothing")
    func exactGatePublishesZero() {
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstDts: 44_000, desiredTfdtPts: 44_000) == 0)
    }

    @Test("a late gate is unchanged, because the pin already made the two axes agree")
    func lateGateUnchanged() {
        // Pre-AE#408 behaviour on the same fixture: the gate opened at 55.0 for a boundary at 52.0
        // and the pin moved the first frame down to 52.0, so the content sits 3 s above the axis.
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstDts: 55_000, desiredTfdtPts: 52_000) == 3_000)
    }

    @Test("an unresolved timestamp publishes nothing rather than a garbage offset")
    func unresolvedPublishesZero() {
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstDts: .min, desiredTfdtPts: 52_000) == 0)
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstDts: 43_000, desiredTfdtPts: .min) == 0)
    }

    // MARK: - The offset composes when a segment is placed

    @Test("the first placement of a session establishes the axis")
    func firstPlacementEstablishesTheAxis() {
        #expect(HLSVideoEngine.axisShift(after: 0, placing: -9.0) == -9.0)
    }

    @Test("an axis-true segment leaves the axis where it is")
    func axisTrueSegmentChangesNothing() {
        // The reporter's seek burst: seg179 was cut on its own boundary, and the run kept -14.056.
        #expect(HLSVideoEngine.axisShift(after: -14.056, placing: 0) == -14.056)
    }

    @Test("re-placing the segment the gate opened into adds its offset again")
    func rePlacingTheAnchorComposes() {
        // Measured: resume 53 reads -9.000, and a seek that re-fetches that same segment reads -18.000.
        #expect(HLSVideoEngine.axisShift(after: -9.0, placing: -9.0) == -18.0)
        // And at the deepest tier of the tiered fixture, -11.000 -> -22.000.
        #expect(HLSVideoEngine.axisShift(after: -11.0, placing: -11.0) == -22.0)
    }

    @Test("a later epoch's own re-aim composes onto what the timeline already carries")
    func newEpochComposesOntoTheOldAxis() {
        // Measured: a -9.000 run, seek to 60, producer restarts at seg12 and re-aims 5 s, reads -14.000.
        #expect(HLSVideoEngine.axisShift(after: -9.0, placing: -5.0) == -14.0)
        // Tiered fixture: a -11.000 run whose seek restarts at seg23 re-aiming 7 s reads -18.000.
        #expect(HLSVideoEngine.axisShift(after: -11.0, placing: -7.0) == -18.0)
    }

    // MARK: - Where the new axis starts applying

    @Test("the seam is the advertised start read through the axis already in effect")
    func seamIsReadThroughTheOldAxis() {
        // seg12 advertised at 48.0 landing on a timeline that already carries -9.0 begins at item 57.0,
        // which is where the picture probe found its first frame.
        #expect(HLSVideoEngine.seamItemSeconds(advertisedStart: 48.0, currentShift: -9.0) == 57.0)
    }

    @Test("on a fresh timeline the seam is the advertised start itself")
    func seamOnAFreshTimeline() {
        #expect(HLSVideoEngine.seamItemSeconds(advertisedStart: 52.0, currentShift: 0) == 52.0)
    }

    // MARK: - What a producer restart does to the record

    @Test("a new epoch drops what older epochs claimed at and above its own index")
    func newEpochDropsTheIndicesItRewrites() {
        let table = HLSVideoEngine.epochShiftTable([11: -0.875, 13: -9.0], recordingEpochAt: 12, shift: -5.0)
        #expect(table == [11: -0.875, 12: -5.0])
        // seg13 is now cut on its own boundary by the new producer, so claiming -9.0 for it would be
        // the table-shaped mistake round 1 avoided by keeping a single pair.
        #expect(table[13] == nil)
    }

    @Test("an epoch that opened on its boundary is recorded as worth nothing")
    func exactEpochIsRecordedAsZero() {
        // Round 2 asserted the opposite, that such an epoch is not recorded at all, and that
        // assertion was the AE#448 defect written down: the entry is what says "an epoch begins
        // here", so dropping it left the stretch the epoch had just taken over folding with the seam
        // underneath it. Worth nothing to the axis VALUE is not the same as nothing to record.
        #expect(HLSVideoEngine.epochShiftTable([13: -9.0], recordingEpochAt: 20, shift: 0)
                == [13: -9.0, 20: 0])
    }

    @Test("segments below a restart keep the offset their bytes still carry")
    func segmentsBelowARestartAreUntouched() {
        let table = HLSVideoEngine.epochShiftTable([2: -0.875], recordingEpochAt: 13, shift: -9.0)
        #expect(table == [2: -0.875, 13: -9.0])
    }

    // MARK: - What a seek does to the axis

    @Test("a sub-second axis does not survive a seek")
    func subSecondAxisSnaps() {
        // Measured: -0.500 and -0.875 both read axisErr 0.000 after a seek.
        #expect(HLSVideoEngine.axisShiftAfterSeek(-0.5) == 0)
        #expect(HLSVideoEngine.axisShiftAfterSeek(-0.875) == 0)
        #expect(HLSVideoEngine.axisShiftAfterSeek(0.375) == 0)
    }

    @Test("a second or more survives a seek unchanged")
    func secondOrMoreSurvivesASeek() {
        // Measured, every one of them across a seek: -1.000, -1.083, -1.292, -1.500, -3.000,
        // -4.000, -7.000, -9.000, -11.000. The boundary sits between -0.875 and -1.000.
        for shift in [-1.0, -1.083, -1.292, -1.5, -3.0, -4.0, -7.0, -9.0, -11.0, -22.0] {
            #expect(HLSVideoEngine.axisShiftAfterSeek(shift) == shift)
        }
    }

    @Test("an axis of zero stays zero")
    func zeroStaysZero() {
        #expect(HLSVideoEngine.axisShiftAfterSeek(0) == 0)
    }

    // MARK: - What counts as a placement

    @Test("every fetch places a segment, whatever its order")
    func everyFetchIsAPlacement() {
        #expect(VideoSegmentProvider.placesSegmentAnew(index: 12, previousTarget: 11))
        // The reporter's burst: seg179 after seg169, which round 1 called a fresh run and this calls
        // what it is, a placement of a segment worth nothing.
        #expect(VideoSegmentProvider.placesSegmentAnew(index: 179, previousTarget: 169))
        #expect(VideoSegmentProvider.placesSegmentAnew(index: 3, previousTarget: 11))
    }

    @Test("the same index again is a retry of one placement, not a second one")
    func repeatedFetchIsARetry() {
        // Counting it twice would move the axis by an offset AVPlayer applied once; the restart path
        // serves exactly this shape (`fetch seg12 prev=seg12` right after a producer rebuild).
        #expect(!VideoSegmentProvider.placesSegmentAnew(index: 11, previousTarget: 11))
    }

    @Test("the session's first fetch is a placement")
    func firstFetchIsAPlacement() {
        #expect(VideoSegmentProvider.placesSegmentAnew(index: 13, previousTarget: -1))
    }
}

/// AE#418 round 3 (rrgomes, retest on 6.45.0): after a six-seek burst the captions ran 2 to 3 s BEHIND
/// the picture, the opposite direction from every earlier round, and the composition is why.
///
/// Round 2 measured the rule correctly and applied it to the wrong events. **A fetch is not a
/// placement.** During a burst AVPlayer asks for a segment and seeks away before the bytes are used,
/// so nothing about its timeline moves, while this side had already folded that epoch's worth into the
/// axis. Every later placement then composed onto a base AVPlayer never carried:
///
/// ```
/// seg88  placed (advertised 352.936s, worth -3.045s): axis  0.000 ->  -3.045   [resume]
/// seg187 placed (advertised 748.122s, worth -2.043s): axis -3.045 ->  -5.088   [seek 748, restart]
/// seg197 placed (advertised 788.204s, worth -5.589s): axis -5.088 -> -10.677   [seek 788, restart]
/// ```
///
/// The reporter's own host log carries the disproof: at the failing moment the item's loaded range
/// began at `791.2`, and `788.204 + 3.045 = 791.249`. AVPlayer composed seg197 onto the RESUME axis,
/// so the honest axis was `-8.634` and the published one was 2.043 s too deep, which is the caption
/// lag he heard.
///
/// So the axis stops being predicted. `loadedTimeRanges` is the on-device account of where AVPlayer
/// put a segment, one subtraction inverts the placement, and the harness confirms the oracle exactly:
/// on `tc-cues-lie.mkv` a resume that predicts a seam at `52.000` reads `loaded [52.000-64.958]`, and
/// after a far seek that predicts `21.000` it reads `[21.000-38.622]`.
@Suite("AE#418 round 3: a placement is measured, not assumed")
struct Issue418PlacementReconcileTests {

    // MARK: - Reading the base out of the placement

    @Test("the placement inverts to the base AVPlayer composed onto")
    func placementInvertsToBase() {
        // The reporting case: advertised 788.204, held from item 791.249.
        #expect(abs(HLSVideoEngine.measuredPlacementBase(
            advertisedStart: 788.204, observedItemStart: 791.249) - -3.045) < 0.001)
        // The harness case, where the assumption held: advertised 12.000, held from item 21.000.
        #expect(abs(HLSVideoEngine.measuredPlacementBase(
            advertisedStart: 12.0, observedItemStart: 21.0) - -9.0) < 0.001)
    }

    @Test("a placement that landed where it was predicted needs no correction")
    func agreesWithThePrediction() {
        // ARM C on the harness: resume at -9.000, a far seek whose restart re-aims 1.667 s more, and
        // the picture reads -10.667 for the rest of the run. Nothing here may move.
        #expect(HLSVideoEngine.placementVerdict(
            advertisedStart: 12.0, worth: -1.667, assumedBase: -9.0,
            observedItemStart: 21.0, publishedAxes: [0, -9.0]) == .agrees)
    }

    @Test("the reporter's burst: the axis collapses onto the base AVPlayer actually used")
    func correctsTheBurstCase() {
        let verdict = HLSVideoEngine.placementVerdict(
            advertisedStart: 788.204, worth: -5.589, assumedBase: -5.088,
            observedItemStart: 791.2, publishedAxes: [0, -3.045, -5.088])
        guard case .corrects(let base, let axis, let seam) = verdict else {
            Issue.record("expected a correction, got \(verdict)")
            return
        }
        #expect(abs(base - -3.045) < 0.001)
        // -8.634, not -10.677: the middle fetch moved nothing, so its worth is not in the axis.
        #expect(abs(axis - -8.634) < 0.001)
        // And the seam belongs at the placement, which is what the item reported holding.
        #expect(abs(seam - 791.249) < 0.001)
    }

    @Test("a corrected placement stays corrected when it is read a second time")
    func correctionDoesNotOscillate() {
        // The correction republishes, which re-arms the check. Its second reading must agree, or the
        // axis would flap between two values for as long as the item holds the range.
        #expect(HLSVideoEngine.placementVerdict(
            advertisedStart: 788.204, worth: -5.589, assumedBase: -3.045,
            observedItemStart: 791.2, publishedAxes: [0, -3.045, -5.088, -8.634]) == .agrees)
    }

    @Test("a reading that matches no published axis is refused")
    func refusesAnUnrecognisedReading() {
        // A range read before the bytes this seam describes have landed, or one eviction has trimmed
        // up from the placement. Both produce a number; neither produces an axis this side handed out.
        let verdict = HLSVideoEngine.placementVerdict(
            advertisedStart: 788.204, worth: -5.589, assumedBase: -5.088,
            observedItemStart: 812.5, publishedAxes: [0, -3.045, -5.088])
        guard case .unrecognised = verdict else {
            Issue.record("expected the reading to be refused, got \(verdict)")
            return
        }
    }

    @Test("a base within a frame of the assumption is the assumption")
    func toleratesAFrame() {
        // 24 fps is 0.042 s. A placement is reported in seconds by a live buffer, and a difference
        // that small cannot move a picture.
        #expect(HLSVideoEngine.placementVerdict(
            advertisedStart: 788.204, worth: -5.589, assumedBase: -5.088,
            observedItemStart: 793.25, publishedAxes: [0, -3.045, -5.088]) == .agrees)
    }

    @Test("a snapped axis leaves no placement to measure")
    func snapClearsTheRecord() {
        // What the check WOULD do to a record that survived the sub-second snap, which is why
        // `snapAxisAfterSeek` clears it: AVPlayer discarded the offset and put the run on the raw
        // playlist, so the base measures 0.000, 0.000 is a published axis, and the correction hands
        // back `0 + worth`, the very axis the snap had just removed.
        #expect(HLSVideoEngine.placementVerdict(
            advertisedStart: 44.0, worth: -0.5, assumedBase: -0.5,
            observedItemStart: 44.0, publishedAxes: [0, -0.5])
            == .corrects(base: 0, axis: -0.5, seam: 44.0))
    }

    // MARK: - Which range describes the picture

    @Test("the range holding the playhead is the one that was placed")
    func rangeHoldingThePlayhead() {
        let ranges = [(352.9, 400.0), (791.2, 816.6)]
        #expect(HLSVideoEngine.placementRangeStart(ranges: ranges, itemClock: 810.868) == 791.2)
        #expect(HLSVideoEngine.placementRangeStart(ranges: ranges, itemClock: 360.0) == 352.9)
    }

    @Test("a playhead no range holds says nothing about a placement")
    func noRangeHoldsThePlayhead() {
        // The state right after a seek, before AVPlayer has taken the bytes. Answering from the range
        // that happens to exist is how a check invents a placement out of the previous epoch.
        #expect(HLSVideoEngine.placementRangeStart(
            ranges: [(352.9, 400.0)], itemClock: 810.868) == nil)
        #expect(HLSVideoEngine.placementRangeStart(ranges: [], itemClock: 810.868) == nil)
    }

    @Test("overlapping ranges resolve to the newest placement")
    func overlappingRangesTakeTheHighestStart() {
        // Two runs can cover one position while the older one is still being evicted; the picture is
        // the one placed last.
        #expect(HLSVideoEngine.placementRangeStart(
            ranges: [(780.0, 800.0), (791.2, 816.6)], itemClock: 795.0) == 791.2)
    }

    // MARK: - The candidate set

    @Test("the published axes are recorded once each, newest last")
    func recordsPublishedAxes() {
        var values = [0.0]
        values = HLSVideoEngine.recordingPublishedAxis(values, value: -3.045)
        values = HLSVideoEngine.recordingPublishedAxis(values, value: -5.088)
        values = HLSVideoEngine.recordingPublishedAxis(values, value: -5.088)
        #expect(values == [0.0, -3.045, -5.088])
    }

    @Test("the candidate set is bounded")
    func boundedCandidateSet() {
        var values = [0.0]
        for i in 1...(HLSVideoEngine.maxPublishedAxisValues + 10) {
            values = HLSVideoEngine.recordingPublishedAxis(values, value: Double(i) * -1.5)
        }
        #expect(values.count == HLSVideoEngine.maxPublishedAxisValues)
        // The newest survives, which is the one a placement is most likely to have composed onto.
        #expect(abs(values.last! - Double(HLSVideoEngine.maxPublishedAxisValues + 10) * -1.5) < 0.001)
    }

    @Test("a measured base collapses onto the nearest published axis, not the newest")
    func collapsesOntoTheNearest() {
        #expect(HLSVideoEngine.carriedAxisMatch(
            measuredBase: -3.05, carried: [0, -3.045, -5.088]) == -3.045)
        #expect(HLSVideoEngine.carriedAxisMatch(
            measuredBase: -4.2, carried: [0, -3.045, -5.088]) == nil)
        #expect(HLSVideoEngine.carriedAxisMatch(measuredBase: .nan, carried: [0, -3.045]) == nil)
    }
}
