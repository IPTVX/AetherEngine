import Foundation
import Testing
@testable import AetherEngine

/// AE#446 round 7: a source that is merely LATE is not a source that has stopped.
///
/// Closing the window is irreversible for the item that reads the ENDLIST, so it is paid for with an
/// item swap and a visible seam when the source comes back. It used to fire on the same threshold as
/// the blocking-reload withdrawal, which is cheap and reversible, so every hiccup a target duration
/// long committed the session (reported from the field on a 1 s-segment stack: a 3.0 s stall in the
/// source read, 14 s of runway still ahead, the source delivering again 0.6 s later, and a swap 17 s
/// after that). The wait is now bounded twice: by the clock, and by the runway left to wait with.
@Suite("AE#446 round 7 outage close deadline")
struct Issue446OutageCloseDeadlineTests {

    /// 4 s segments seal TARGETDURATION 6 (`ceil(1.5 x cut target)`), so patience is 9 s and the close
    /// deadline 18 s: two numbers a reader can follow through the test. What the runway has to beat is
    /// whatever is left of that 18 s at the moment it is asked.
    private func makeLiveProvider(segments segmentCount: Int)
        -> (provider: VideoSegmentProvider, cache: SegmentCache) {
        let cache = SegmentCache(forwardWindow: 40, backwardWindow: 40)
        let provider = VideoSegmentProvider(
            cache: cache,
            segments: [],
            codecsString: "avc1.640029,mp4a.40.2",
            supplementalCodecs: nil,
            resolution: (1920, 1080),
            videoRange: .sdr,
            frameRate: 25,
            hdcpLevel: nil,
            sourceBitrate: 8_000_000,
            isLive: true,
            liveWindowSizing: LiveWindowSizing(targetSegmentDurationSeconds: 4.0,
                                               dvrWindowSeconds: 1800)
        )
        for i in 0..<segmentCount {
            provider.appendLiveSegment(index: i, startSeconds: Double(i) * 4.0, durationSeconds: 4.0)
        }
        #expect(provider.liveTargetDurationSeconds(maxSegmentDuration: 4.0) == 6)
        return (provider, cache)
    }

    @Test("the silence that withdraws the blocking-reload advert does not close the window")
    func lateSourceKeepsTheWindowLive() {
        let (provider, cache) = makeLiveProvider(segments: 20)
        cache.declareTarget(2) // 17 segments / 68 s of runway ahead of the fetch point
        provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 10.0) // 1.7 x TD

        // The cheap half still fires exactly where it did: past AVPlayer's own patience a held poll
        // can only starve a client the cache could feed.
        #expect(provider.liveDeliveryStalled)
        // The expensive half does not. This pair is the whole round.
        #expect(!provider.liveOutageEndlist)
        #expect(!provider.liveOutageEndlistLatched)
    }

    @Test("past the close deadline the window is served as a finished asset")
    func quietSourceClosesTheWindow() {
        let (provider, cache) = makeLiveProvider(segments: 20)
        cache.declareTarget(2)
        provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 18.5) // > 3 x TD

        #expect(provider.liveOutageEndlist)
        #expect(provider.liveOutageEndlistLatched)
    }

    @Test("a runway that cannot reach the deadline closes at once")
    func shallowRunwayClosesAtOnce() {
        let (provider, cache) = makeLiveProvider(segments: 20)
        cache.declareTarget(18) // 1 segment / 4 s left against 8 s of clock: it does not reach
        provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 10.0) // late, nowhere near quiet

        #expect(provider.liveOutageEndlist)
    }

    /// AE#520, the reporter's shape: a viewer near the live edge, a gap the deadline was built to
    /// absorb, and a runway that the old `2 x TD` constant called shallow. Three segments is 12 s,
    /// exactly the old floor, and 12 s of content against 8 s of remaining clock reaches the deadline
    /// with room to spare, so nothing may be closed and no item may be swapped.
    @Test("a runway that outlasts the deadline waits it out instead of closing")
    func runwayThatReachesTheDeadlineIsNotClosedOn() {
        let (provider, cache) = makeLiveProvider(segments: 20)
        cache.declareTarget(16) // 3 segments / 12 s ahead of the fetch point
        provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 10.0) // 1.7 x TD, late not quiet

        #expect(!provider.liveOutageEndlist)
        #expect(!provider.liveOutageEndlistLatched)
        // And the clock still closes it when the source really is gone, on the same runway.
        provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 8.6) // 18.6 s total, past 18 s
        #expect(provider.liveOutageEndlist)
    }

    /// The bound in isolation, so the rule is readable without a provider around it.
    @Test("the runway bound is the clock, not a constant")
    func runwayBoundIsMeasuredAgainstTheClock() {
        // 12 s of content, 18 s deadline, 10 s of silence: 8 s of clock left, the content reaches it.
        #expect(!LiveEdgePolicy.outageCloseOnRunway(runwaySeconds: 12, silenceSeconds: 10,
                                                    deadlineSeconds: 18))
        // The same content one poll later does not.
        #expect(LiveEdgePolicy.outageCloseOnRunway(runwaySeconds: 7, silenceSeconds: 10,
                                                   deadlineSeconds: 18))
        // Equal closes: arriving at the deadline with nothing left is not carrying the wait to it.
        #expect(LiveEdgePolicy.outageCloseOnRunway(runwaySeconds: 8, silenceSeconds: 10,
                                                   deadlineSeconds: 18))
        // Past the deadline this bound has nothing left to say (no clock to fail to reach), and it
        // does not have to: `quiet` is what closes the window there. Pinned so the pair is not read
        // as a gap.
        #expect(!LiveEdgePolicy.outageCloseOnRunway(runwaySeconds: 40, silenceSeconds: 25,
                                                    deadlineSeconds: 18))
        // A deeply timeshifted viewer waits the whole deadline out on any silence under it.
        #expect(!LiveEdgePolicy.outageCloseOnRunway(runwaySeconds: 68, silenceSeconds: 0.1,
                                                   deadlineSeconds: 18))
    }

    @Test("a source that has not missed its cadence closes nothing, however little runway is left")
    func aHealthySourceIsNeverClosedOn() {
        let (provider, cache) = makeLiveProvider(segments: 20)
        cache.declareTarget(17)
        provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 4.0) // inside its own cadence

        #expect(!provider.liveOutageEndlist)
    }

    @Test("a consumer at the end of the window has nothing to serve as a finished asset")
    func consumerAtTheEndIsNotClosedOn() {
        let (provider, cache) = makeLiveProvider(segments: 20)
        cache.declareTarget(19)
        provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 60.0)

        #expect(!provider.liveOutageEndlist)
    }

    @Test("the recovery reading stays on the strict cadence, not on the close deadline")
    func recoveryIsStillTheStrictReading() {
        let (provider, cache) = makeLiveProvider(segments: 20)
        cache.declareTarget(2)
        provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 18.5)
        #expect(provider.liveOutageEndlist)

        // 12 s of silence is under the close deadline but past the cadence: a window that is already
        // closed must NOT read as recovered there, or the swap lands in a window whose source is dead.
        let (stillQuiet, stillQuietCache) = makeLiveProvider(segments: 20)
        stillQuietCache.declareTarget(2)
        stillQuiet.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 18.5)
        #expect(stillQuiet.liveOutageEndlist)
        #expect(!stillQuiet.liveOutageProductionResumed)
    }

    @Test("the deadline never waits past the producer's own patience with a silent source")
    func deadlineStaysInsideTheStarvationExit() {
        // The ordinary case: three target durations, nowhere near the exit.
        #expect(LiveEdgePolicy.outageCloseSilenceSeconds(targetDuration: 2) == 6.0)
        #expect(LiveEdgePolicy.outageCloseSilenceSeconds(targetDuration: 6) == 18.0)
        // A bursty relay seals its TARGETDURATION from an arrival cadence, and 3 x TD then lands past
        // the 35 s starvation exit, where the window would never be closed at all. The deadline is
        // pulled back in front of it, and never below the moment the source is late.
        for td in 1...30 {
            let deadline = LiveEdgePolicy.outageCloseSilenceSeconds(targetDuration: td)
            let late = LiveEdgePolicy.unchangedPlaylistPatienceMultiplier * Double(td)
            #expect(deadline >= late)
            #expect(deadline <= max(late, HLSSegmentProducer.liveSourceStarvationTimeoutSeconds - late))
        }
        #expect(LiveEdgePolicy.outageCloseSilenceSeconds(targetDuration: 14) == 21.0)
    }

    @Test("the close deadline is strictly later than the client's own patience")
    func theTwoThresholdsAreNotTheSameNumber() {
        // The defect in one line: an irreversible decision sized by a threshold chosen for a
        // withdrawal that costs nothing.
        #expect(LiveEdgePolicy.outageCloseSilenceMultiplier
                > LiveEdgePolicy.unchangedPlaylistPatienceMultiplier)
        // And the wait stays well inside what the client will sit through: measured at 13 x TD with
        // the window open and the advert withdrawn.
        #expect(LiveEdgePolicy.outageCloseSilenceMultiplier <= 4.0)
    }
}
