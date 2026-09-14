import Foundation
import Testing
@testable import AetherEngine

/// AE#523: a healthy source was judged by the client's patience, so every ordinary delivery closed the
/// window.
///
/// Captured on a device. The upstream hands over about 6 s of media at a time and the cutter makes 3 s
/// segments of it, so segments finalize in PAIRS 30 ms apart and then nothing is heard for the rest of
/// the delivery interval:
///
///     15:55:34.708  live seg-17 finalized: dur=3.000s
///     15:55:34.736  live seg-18 finalized: dur=3.000s
///     15:55:41.251  live seg-19 finalized: dur=3.000s
///     15:55:41.277  live seg-20 finalized: dur=3.000s
///
/// TARGETDURATION sealed at 4, so the client's patience is 6.0 s, and the delivery interval runs 6.50
/// to 6.85 s. Every single burst was therefore read as the source having stopped: ENDLIST, the item
/// played out its runway, and a swap the viewer sees. Two of them 31.4 s apart in the captured minute,
/// on a session delivering 72 s of media per 64 s of wall clock, which is to say not behind at all.
@Suite("AE#523 a source is judged by its own delivery rhythm")
struct Issue523SourceCadenceLatenessTests {

    /// The device capture, as the meter sees it: one short interval inside each pair, one wide one
    /// between pairs. The short ones are inside a single delivery and the meter drops them (AE#524).
    private var fieldIntervals: [Double] {
        [0.028, 6.85, 0.032, 6.52, 0.026, 6.59, 0.028, 6.50, 0.032, 6.85, 0.033, 6.53]
    }

    private func meter(_ intervals: [Double]) -> SourceDeliveryCadenceMeter {
        var m = SourceDeliveryCadenceMeter()
        for i in intervals { m.note(intervalSeconds: i) }
        return m
    }

    @Test("the meter reads the wide gap, not the pair")
    func theMeterReadsTheDeliveryInterval() {
        let cadence = meter(fieldIntervals).cadenceSeconds
        #expect(cadence != nil)
        // The second largest of what is left once the intra-delivery intervals are dropped.
        #expect(abs((cadence ?? 0) - 6.85) < 0.001)
        // A mean would have read 2.9 s here, which is not an interval this source ever takes.
        #expect((cadence ?? 0) > 6.0)
    }

    /// AE#524: the same meter, on a device, read "it delivers every 0.04s" for a source delivering
    /// every 6.5 s, and the window then closed on the first quiet stretch. A backlogged join fills the
    /// whole sample window with intervals INSIDE one delivery: the origin hands over its window at I/O
    /// speed, the cutter finalizes five segments in 55 ms, and every one of those is 30 ms from the
    /// last. Dropping the single worst sample then threw away the only real interval there was.
    @Test("a backlogged join is one delivery, not five")
    func abacklogIsNotARhythm() {
        // The device capture, verbatim: seg-0 to seg-4 of a fastZap join.
        let backlog = meter([0.039, 0.016, 3.532, 0.036])
        // Not "every 0.04s", which is what the close fired on. One real interval is not a rhythm
        // either, so the honest answer here is that this meter has nothing to say yet.
        #expect(backlog.cadenceSeconds == nil)
        // Which leaves the client's own patience, and that is NOT enough on this source: 1.5 x
        // TARGETDURATION is 6.0 s against a 6.45 s quiet stretch. The ingest's arrival meter is what
        // covers the start, and the test below is the one that matters for a fastZap join.
        #expect(LiveEdgePolicy.sourceLateSeconds(targetDuration: 4,
                                                 cadenceSeconds: backlog.cadenceSeconds) == 6.0)
    }

    @Test("the ingest's own arrival meter is the better measurement, and it is there sooner")
    func theIngestFloorCarriesTheStart() {
        // The upstream's measured arrival cadence, which this session had before the provider had
        // finalized its second segment: 6.000 s, so a 6.45 s quiet stretch is not late.
        let late = LiveEdgePolicy.sourceLateSeconds(targetDuration: 4, cadenceSeconds: 6.0)
        #expect(abs(late - 7.5) < 0.001)
        #expect(6.45 < late)
    }

    @Test("none of the captured gaps is late any more, and every one of them used to be")
    func theFieldCaptureNoLongerReadsAsAnOutage() {
        let cadence = meter(fieldIntervals).cadenceSeconds
        let late = LiveEdgePolicy.sourceLateSeconds(targetDuration: 4, cadenceSeconds: cadence)
        // The four silences the log printed before it closed the window.
        for silence in [6.02, 6.52, 6.56, 6.85] {
            #expect(silence <= late)
            // The old reading, TARGETDURATION alone, called every one of them a stopped source.
            #expect(silence > LiveEdgePolicy.unchangedPlaylistPatienceMultiplier * 4)
        }
    }

    @Test("a source that misses two of its own deliveries still closes the window")
    func arealOutageStillCloses() {
        let cadence = meter(fieldIntervals).cadenceSeconds
        let late = LiveEdgePolicy.sourceLateSeconds(targetDuration: 4, cadenceSeconds: cadence)
        let deadline = LiveEdgePolicy.outageCloseSilenceSeconds(targetDuration: 4, cadenceSeconds: cadence)
        #expect(deadline > late)
        // One missed delivery is late; two is the deadline.
        #expect(2 * 6.85 >= deadline)
        #expect(30.0 > deadline)
    }

    @Test("one outage does not teach the meter to be patient with the next")
    func theWorstSampleIsDropped() {
        // The same capture with a 30 s stall recorded in the middle of it, which is what happens when
        // the source comes back: the gap is an interval like any other.
        var withStall = fieldIntervals
        withStall[5] = 30.0
        let cadence = meter(withStall).cadenceSeconds
        #expect(abs((cadence ?? 0) - 6.85) < 0.001)
        // Two stalls inside one window do move it, and a source that stalls twice in six deliveries
        // has earned the wider threshold.
        var twice = withStall
        twice[7] = 28.0
        #expect((meter(twice).cadenceSeconds ?? 0) > 20)
    }

    @Test("a source finer than its target duration keeps the client's patience")
    func afineSourceIsUnchanged() {
        // 1 s deliveries against TARGETDURATION 4: judging this source by its own rhythm would call it
        // dead a second after every segment, so the floor is the client's patience and nothing moves.
        let cadence = meter([1.0, 1.02, 0.98, 1.01, 1.0, 1.03]).cadenceSeconds
        #expect(LiveEdgePolicy.sourceLateSeconds(targetDuration: 4, cadenceSeconds: cadence)
                == LiveEdgePolicy.unchangedPlaylistPatienceMultiplier * 4)
    }

    @Test("no measurement means the reading is exactly what it was before")
    func noCadenceIsTheOldBehaviour() {
        for td in 1...30 {
            #expect(LiveEdgePolicy.sourceLateSeconds(targetDuration: td, cadenceSeconds: nil)
                    == LiveEdgePolicy.unchangedPlaylistPatienceMultiplier * Double(td))
            #expect(LiveEdgePolicy.outageCloseSilenceSeconds(targetDuration: td, cadenceSeconds: nil)
                    == LiveEdgePolicy.outageCloseSilenceSeconds(targetDuration: td))
        }
    }

    @Test("a backlogged join has no rhythm to read yet")
    func aBacklogReadsAsNoMeasurement() {
        // An origin that arrives with a window in hand appends it in milliseconds. Reading a rhythm off
        // that would put the threshold under the client's patience on every live join.
        #expect(meter([0.001, 0.002, 0.001]).cadenceSeconds == nil)
        #expect(meter([]).cadenceSeconds == nil)
        let backlog = meter([0.001, 0.002, 0.001, 0.002]).cadenceSeconds
        #expect(LiveEdgePolicy.sourceLateSeconds(targetDuration: 4, cadenceSeconds: backlog)
                == LiveEdgePolicy.unchangedPlaylistPatienceMultiplier * 4)
    }

    @Test("the threshold never waits past the producer's own starvation exit")
    func theCeilingHolds() {
        // A source measured at half a minute per delivery cannot buy a threshold on the far side of the
        // 35 s exit, past which nothing would be served in time to matter.
        let absurd = LiveEdgePolicy.sourceLateSeconds(targetDuration: 4, cadenceSeconds: 30)
        #expect(absurd <= HLSSegmentProducer.liveSourceStarvationTimeoutSeconds
                - LiveEdgePolicy.unchangedPlaylistPatienceMultiplier * 4)
        for cadence in stride(from: 1.0, through: 60.0, by: 0.5) {
            for td in [2, 4, 6, 14] {
                let late = LiveEdgePolicy.sourceLateSeconds(targetDuration: td, cadenceSeconds: cadence)
                let deadline = LiveEdgePolicy.outageCloseSilenceSeconds(targetDuration: td,
                                                                       cadenceSeconds: cadence)
                #expect(late >= LiveEdgePolicy.unchangedPlaylistPatienceMultiplier * Double(td))
                #expect(deadline >= late)
                #expect(deadline <= HLSSegmentProducer.liveSourceStarvationTimeoutSeconds)
            }
        }
    }

    @Test("the meter keeps only a trailing window, so a rhythm change is followed")
    func themeterFollowsTheSource() {
        var m = meter(fieldIntervals)
        // The upstream switches to handing over one segment at a time, every two seconds.
        for _ in 0..<SourceDeliveryCadenceMeter.sampleCount { m.note(intervalSeconds: 2.0) }
        #expect(abs((m.cadenceSeconds ?? 0) - 2.0) < 0.001)
    }
}
