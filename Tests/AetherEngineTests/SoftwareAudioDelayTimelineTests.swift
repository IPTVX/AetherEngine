import Testing
@testable import AetherEngine

/// Pins the source/presentation boundary before exercising it through the actual software host.
@Suite("Software large audio-delay timeline")
struct SoftwareAudioDelayTimelineTests {
    // Failure modes:
    // - Advancing audio moves the video clock to the audio's unshifted source time.
    // - VOD starts skip video merely because audio begins before the available source.
    // - A finite title waits forever for audio that cannot overlap its final video interval.

    /// Both signs retain the exact original video seek target.
    @Test(arguments: [-180.0, 180.0])
    func finiteVideoPositionIsPreserved(delay: Double) {
        let timeline = SoftwareAudioDelayTimeline(delaySeconds: delay)
        #expect(timeline.videoAnchor(sourceOrigin: 0, requestedPosition: 25, isLive: false) == 25)
        #expect(timeline.sourceReadStart(videoPosition: 25) == (delay > 0 ? 0 : 25))
    }

    /// A fresh Live source waits for the offset instead of requesting nonexistent history.
    @Test(arguments: [-180.0, 180.0])
    func liveAnchorUsesAvailableSource(delay: Double) {
        let timeline = SoftwareAudioDelayTimeline(delaySeconds: delay)
        let video = timeline.videoAnchor(sourceOrigin: 1000, requestedPosition: 0, isLive: true)
        #expect(video == 1000 + max(delay, 0))
        #expect(video - delay == 1000 + max(-delay, 0))
    }

    /// Effective arming and lead use the timestamp the renderer receives, not the decoder's PTS.
    @Test
    func negativeDelayArmsAtVideoTime() {
        let timeline = SoftwareAudioDelayTimeline(delaySeconds: -180)
        #expect(timeline.audioPresentationTime(190) == 10)
        #expect(!timeline.admitsAudio(sourceSeconds: 180, videoStart: 25, videoEnd: 300))
        #expect(timeline.admitsAudio(sourceSeconds: 205, videoStart: 25, videoEnd: 300))
    }

    /// Audio beyond a finite video's tail does not extend playback or hold its clock forever.
    @Test
    func finiteBoundariesAllowIntentionalGaps() {
        let positive = SoftwareAudioDelayTimeline(delaySeconds: 180)
        #expect(!positive.admitsAudio(sourceSeconds: 0, videoStart: 0, videoEnd: 60))
        let negative = SoftwareAudioDelayTimeline(delaySeconds: -180)
        #expect(!negative.admitsAudio(sourceSeconds: 179, videoStart: 0, videoEnd: 300))
    }

    /// Public DVR edges exclude audio that has not arrived and history already evicted.
    @Test(arguments: [-180.0, 180.0])
    func availableVideoIntersectsBothStreams(delay: Double) throws {
        let timeline = SoftwareAudioDelayTimeline(delaySeconds: delay)
        let range = try #require(timeline.playableVideoRange(
            sourceFloor: 100, sourceEdge: 600, publicWindow: 240))
        #expect(range.upperBound == 600 + min(delay, 0))
        #expect(range.lowerBound >= 100 + max(delay, 0))
        #expect(range.upperBound - range.lowerBound <= 240)
        #expect(timeline.playableVideoRange(sourceFloor: 100, sourceEdge: 200, publicWindow: 240) == nil)
    }

    /// The existing fine correction keeps its original clock/lead behavior.
    @Test(arguments: [-2.0, 0, 2])
    func ordinaryPathIsUnchanged(delay: Double) {
        let timeline = SoftwareAudioDelayTimeline(delaySeconds: delay)
        #expect(!timeline.requiresAlignment)
        #expect(timeline.audioPresentationTime(10) == 10)
        #expect(timeline.sourceReadStart(videoPosition: 25) == 25)
    }
    /// An evicted cursor cannot retry forever when the retained span is shorter than the delay.
    @Test(arguments: [-180.0, 180.0])
    func insufficientEvictedHistoryFailsImmediately(delay: Double) throws {
        let timeline = SoftwareAudioDelayTimeline(delaySeconds: delay)
        #expect(throws: SoftwareAudioDelayTimeline.RecoveryFailure.insufficientRetainedHistory(delaySeconds: delay)) {
            try timeline.evictionRecoveryTarget(sourceFloor: 200, sourceEdge: 210, isPlaying: true)
        }
        #expect(try timeline.evictionRecoveryTarget(sourceFloor: 200, sourceEdge: 210, isPlaying: false) == nil)
    }

    /// Cushion-only storage can recover from its private complete interval without publishing DVR.
    @Test(arguments: [-180.0, 180.0])
    func privateCushionHistoryCanRecover(delay: Double) throws {
        let timeline = SoftwareAudioDelayTimeline(delaySeconds: delay)
        let target = try timeline.evictionRecoveryTarget(sourceFloor: 10, sourceEdge: 250, isPlaying: true)
        #expect(target == (delay > 0 ? 190 : 10))
    }

}
