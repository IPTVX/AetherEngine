import Testing
import Foundation
@testable import AetherEngine

/// Sodalite#104: `isAtLiveEdge` flips twice per segment in a perfectly healthy live session.
///
/// The edge is a STEP function and the playhead is CONTINUOUS. `noteEdge` moves once per segment
/// cut, by a whole segment duration; the playhead advances smoothly between those moves. So
/// `behindLiveSeconds`, which is their difference, sawtooths from one segment duration down to zero
/// and back, in every live session, with nobody touching anything.
///
/// A tolerance written as a CONSTANT cannot answer a question whose natural amplitude is the segment
/// duration. At 2.0 s against 4 s segments it is under the sawtooth's peak, so the flag toggles:
/// measured on the harness, an untouched 45 s session flipped it 17 times, `behind` running
/// 3.10 -> 2.10 -> 1.10 -> 0.00 and back for the whole run. The host draws its LIVE badge and its
/// "Return to Live" chip from that flag, so the badge greys out on its own and the chip enters the
/// focus order while the viewer is sitting still, which is what was reported. It is also why the
/// chip does not converge: pressing it lands at the edge, and the next cut immediately puts a whole
/// segment between the two again.
///
/// The tolerance is the last observed edge STEP plus the old constant as slack. Right after a cut,
/// the closest a client can be to the new edge is one segment behind it, because the segment that
/// just moved the edge has not been played yet; being that close IS the live edge, and no client can
/// do better without stalling.
@Suite("The live edge tolerance follows the cadence (Sodalite#104)")
struct Sodalite104LiveEdgeCadenceTests {

    /// The measured shape: 4 s segments, ~1 s of playback per tick.
    private func healthySession() -> LiveWindow {
        var w = LiveWindow(windowSeconds: 60)
        w.noteEdge(4)
        w.notePlayhead(4)
        return w   // no TARGETDURATION: these pin the observed-step fallback
    }

    @Test("a healthy session never leaves the edge between two cuts")
    func healthySawtoothStaysAtEdge() {
        var w = healthySession()
        // Two cuts, and the playhead walking the whole way across each of them. This is the run the
        // harness printed: behind peaks at one segment duration right after the cut.
        for cut in 1...2 {
            w.noteEdge(Double(4 + cut * 4))
            for step in 0...4 {
                w.notePlayhead(Double(4 + (cut - 1) * 4) + Double(step))
                #expect(w.isAtEdge,
                        "cut \(cut), \(String(format: "%.1f", w.behindLiveSeconds))s behind")
            }
        }
    }

    @Test("the peak of the sawtooth is exactly one segment, and it used to fail")
    func sawtoothPeakIsOneSegment() {
        var w = healthySession()
        w.noteEdge(8)          // the cut
        w.notePlayhead(4)      // the client has not played into the new segment yet
        #expect(w.behindLiveSeconds == 4)
        #expect(w.behindLiveSeconds > LiveWindow.edgeTolerance)  // the old constant said "not at edge"
        #expect(w.isAtEdge)
    }

    @Test("a viewer who actually rewound is not at the edge")
    func realRewindIsNotAtEdge() {
        var w = healthySession()
        w.noteEdge(8)
        w.notePlayhead(-22)    // 30 s back on the session axis
        #expect(w.behindLiveSeconds == 30)
        #expect(!w.isAtEdge)
    }

    @Test("one segment plus the slack is the boundary")
    func boundaryIsStepPlusSlack() {
        var w = healthySession()
        w.noteEdge(8)
        w.notePlayhead(8 - (4 + LiveWindow.edgeTolerance))
        #expect(w.isAtEdge)                       // exactly at the bound
        w.notePlayhead(8 - (4 + LiveWindow.edgeTolerance) - 0.1)
        #expect(!w.isAtEdge)                      // past it
    }

    @Test("before the first cut the old constant still decides")
    func withoutAStepTheConstantDecides() {
        var w = LiveWindow(windowSeconds: 60)
        w.noteEdge(10)          // the first sample is not a step, it is where the session starts
        w.notePlayhead(8.5)
        #expect(w.isAtEdge)
        w.notePlayhead(7.0)     // 3 s behind, past the constant, and nothing has cut yet
        #expect(!w.isAtEdge)
    }

    @Test("a declared cadence outranks a bursty delivery")
    func targetDurationOutranksTheObservedStep() {
        // The device case: a tuner or transcode route delivers in bursts, so the edge jumps by far
        // more than a segment. Judging by the observed jump made the tolerance as large as the burst,
        // and a viewer who had deliberately rewound was told they were at the live edge. The playlist
        // says how long a segment is; the delivery does not.
        var w = LiveWindow(windowSeconds: 120)
        w.noteTargetDuration(6)
        w.noteEdge(10)
        w.noteEdge(40)          // a 30 s burst
        #expect(w.lastEdgeStepSeconds == 30)
        w.notePlayhead(28)      // 12 s behind: two segments, and a deliberate rewind
        #expect(!w.isAtEdge)
        w.notePlayhead(35)      // 5 s behind: inside the declared segment
        #expect(w.isAtEdge)
    }

    @Test("without a declared cadence the observed step still decides")
    func withoutTargetDurationTheStepDecides() {
        // Remote HLS live and the software live path serve no playlist of ours, so nothing declares
        // a TARGETDURATION there and the observed advance is all there is.
        var w = healthySession()
        w.noteEdge(34)
        w.notePlayhead(14)
        #expect(w.isAtEdge)
        w.noteEdge(38)
        w.notePlayhead(14)
        #expect(!w.isAtEdge)
    }

    @Test("a non-advancing edge sample leaves the step alone")
    func aRepeatedEdgeSampleIsNotAStep() {
        var w = healthySession()
        w.noteEdge(8)
        w.noteEdge(8)           // the same edge published again on the next tick
        w.noteEdge(6)           // and a stale one, which the running maximum ignores
        w.notePlayhead(4)
        #expect(w.behindLiveSeconds == 4)
        #expect(w.isAtEdge)     // still judged against the 4 s step, not against a zeroed one
    }
}
