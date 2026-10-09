import Testing
@testable import AetherEngine

@Suite("SWClockAnchorPolicy (#107 mid-stream-joined sources on the SW demux loop)")
struct SWClockAnchorPolicyTests {

    @Test("fresh load of a zero-based file keeps the load anchor (head-of-stream offset preserved)")
    func freshLoadZeroBased() {
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 0, firstSampleSeconds: 0.256)
        #expect(r.anchorSeconds == 0)
        #expect(r.sessionZeroSeconds == 0)
    }

    @Test("resume keeps the load anchor when the first sample lands at the resume position")
    func resumeAligned() {
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 1000, firstSampleSeconds: 1000.4)
        #expect(r.anchorSeconds == 1000)
        #expect(r.sessionZeroSeconds == 0)
    }

    @Test("mid-stream join anchors at the first sample PTS and exposes it as session zero")
    func midStreamJoin() {
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 0, firstSampleSeconds: 64000.5)
        #expect(r.anchorSeconds == 64000.5)
        #expect(r.sessionZeroSeconds == 64000.5)
    }

    @Test("deviating resume re-anchors and maps position relative to the requested start")
    func midStreamJoinWithResume() {
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 30, firstSampleSeconds: 53126)
        #expect(r.anchorSeconds == 53126)
        #expect(r.sessionZeroSeconds == 53096)
    }

    @Test("non-finite first sample PTS keeps the load anchor")
    func nonFiniteFirstSample() {
        for pts in [Double.nan, .infinity, -.infinity] {
            let r = SWClockAnchorPolicy.resolve(initialSeconds: 0, firstSampleSeconds: pts)
            #expect(r.anchorSeconds == 0)
            #expect(r.sessionZeroSeconds == 0)
        }
    }

    @Test("small negative first PTS stays on the load anchor")
    func smallNegativeFirstPts() {
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 0, firstSampleSeconds: -0.3)
        #expect(r.anchorSeconds == 0)
        #expect(r.sessionZeroSeconds == 0)
    }

    @Test("deviation exactly at the tolerance keeps the load anchor")
    func deviationAtTolerance() {
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 0, firstSampleSeconds: 2.0)
        #expect(r.anchorSeconds == 0)
        #expect(r.sessionZeroSeconds == 0)
    }

    @Test("deviation just past the tolerance re-anchors")
    func deviationPastTolerance() {
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 0, firstSampleSeconds: 2.01)
        #expect(r.anchorSeconds == 2.01)
        #expect(r.sessionZeroSeconds == 2.01)
    }

    @Test("a first sample behind the anchor keeps the load anchor (AE#724 resume preroll)")
    func firstSampleBehindAnchor() {
        // A resume lands on the keyframe at or before the target, and its audio starts with it.
        // Measured on a 10 s GOP: anchor 17.3, first decoded audio 9.984. That is preroll the
        // skip threshold and the synchronizer discard, not a source that starts elsewhere.
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 17.3, firstSampleSeconds: 9.984)
        #expect(r.anchorSeconds == 17.3)
        #expect(r.sessionZeroSeconds == 0)
    }

    @Test("large stale-audio lead advances startup to the first video sample")
    func largeStartupAVSkew() throws {
        let correction = try #require(
            SWClockAnchorPolicy.startupAVSkewCorrection(
                initialSeconds: 0,
                firstAudioSampleSeconds: 32075.353,
                firstVideoSampleSeconds: 32086.445
            )
        )

        #expect(correction.clockResolution.anchorSeconds == 32086.445)
        #expect(correction.clockResolution.sessionZeroSeconds == 32086.445)
        #expect(correction.discardAudioBeforeSeconds == 32086.445)
    }

    @Test("normal audio lead preserves the original startup anchor")
    func normalStartupAVSkew() {
        let correction = SWClockAnchorPolicy.startupAVSkewCorrection(
            initialSeconds: 0,
            firstAudioSampleSeconds: 0.1,
            firstVideoSampleSeconds: 0.8
        )

        #expect(correction == nil)
    }

    @Test("video-leading startup does not move the clock backwards")
    func videoLeadsAudioAtStartup() {
        let correction = SWClockAnchorPolicy.startupAVSkewCorrection(
            initialSeconds: 0,
            firstAudioSampleSeconds: 1.0,
            firstVideoSampleSeconds: 0.2
        )

        #expect(correction == nil)
    }

    @Test("startup audio before the corrected video anchor is discarded")
    func staleStartupAudioIsDiscarded() {
        #expect(
            SWClockAnchorPolicy.shouldDiscardStartupAudioSample(
                sampleSeconds: 32086.400,
                discardBeforeSeconds: 32086.445
            )
        )
    }

    @Test("startup audio at the corrected video anchor is retained")
    func alignedStartupAudioIsRetained() {
        #expect(
            !SWClockAnchorPolicy.shouldDiscardStartupAudioSample(
                sampleSeconds: 32086.445,
                discardBeforeSeconds: 32086.445
            )
        )
    }

    /// A seek after stale-audio correction must use the corrected video origin.
    @Test("session seek after startup correction uses the first video timestamp as zero")
    func test_sourceSeconds_afterStartupCorrection_usesVideoOrigin() throws {
        // Arrange — stale audio forces the first video sample to become session zero.
        let correction = try #require(
            SWClockAnchorPolicy.startupAVSkewCorrection(
                initialSeconds: 0,
                firstAudioSampleSeconds: 32075.353,
                firstVideoSampleSeconds: 32086.445
            )
        )

        // Act — carry a later session seek onto the source timestamp axis.
        let sourceSeconds = SWClockAnchorPolicy.sourceSeconds(
            forSession: 15,
            sessionZeroSeconds: correction.clockResolution.sessionZeroSeconds
        )

        // Assert — the seek advances from video, never the discarded audio preroll.
        #expect(abs(sourceSeconds - 32101.445) < 1e-9)
        #expect(abs(sourceSeconds - correction.clockResolution.anchorSeconds - 15) < 1e-9)
    }

    /// A corrected resumed load retains the requested position on its session axis.
    @Test("session seek after resumed startup correction preserves the requested resume position")
    func test_sourceSeconds_afterResumedStartupCorrection_preservesResumePosition() throws {
        // Arrange — playback resumes at session 30 with stale audio before the first video.
        let correction = try #require(
            SWClockAnchorPolicy.startupAVSkewCorrection(
                initialSeconds: 30,
                firstAudioSampleSeconds: 32075.353,
                firstVideoSampleSeconds: 32086.445
            )
        )

        // Act — seek fifteen seconds beyond the requested resume position.
        let sourceSeconds = SWClockAnchorPolicy.sourceSeconds(
            forSession: 45,
            sessionZeroSeconds: correction.clockResolution.sessionZeroSeconds
        )

        // Assert — carrying the resume offset advances fifteen source seconds, not forty-five.
        #expect(abs(sourceSeconds - 32101.445) < 1e-9)
        #expect(abs(sourceSeconds - correction.clockResolution.anchorSeconds - 15) < 1e-9)
    }

    @Test("a first sample far behind the anchor keeps it too")
    func firstSampleFarBehindAnchor() {
        // A reposition that fell back to the head of the file: the video skip threshold still
        // stands at the anchor, so a clock moved back to the head would play audio under a
        // picture that cannot present until the anchor anyway.
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 64000, firstSampleSeconds: 10)
        #expect(r.anchorSeconds == 64000)
        #expect(r.sessionZeroSeconds == 0)
    }

    @Test("a large negative first PTS on a cold start keeps the zero anchor")
    func largeNegativeFirstPts() {
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 0, firstSampleSeconds: -5)
        #expect(r.anchorSeconds == 0)
        #expect(r.sessionZeroSeconds == 0)
    }

    // MARK: - Session zero for a resume on an offset-origin source

    @Test("a resume on a source whose timestamps start at 600 s carries the origin as session zero")
    func resumeOnOffsetOrigin() {
        // Measured on `-output_ts_offset 600`: a 17.3 s resume landed on the source's first
        // packet (600.0) while publishing 18.2, because the target reached the demuxer unconverted.
        #expect(SWClockAnchorPolicy.resumeSessionZero(sourceOriginSeconds: 599.979) == 599.979)
    }

    @Test("an origin inside the tolerance stays a zero-based source, as on a cold start")
    func resumeOnNearZeroOrigin() {
        for origin in [0, 0.021, 1.4, 2.0] {
            #expect(SWClockAnchorPolicy.resumeSessionZero(sourceOriginSeconds: origin) == 0)
        }
    }

    @Test("an unknown or negative origin is no session zero")
    func resumeOnUnknownOrigin() {
        for origin in [Double.nan, .infinity, -5] {
            #expect(SWClockAnchorPolicy.resumeSessionZero(sourceOriginSeconds: origin) == 0)
        }
    }

    /// A resume target stays ahead of keyframe preroll even when audio and video are skewed.
    @Test("startup correction does not move a resume anchor back onto video preroll")
    func test_startupAVSkewCorrection_videoBeforeResumeAnchor_preservesAnchor() {
        // Arrange — both first samples precede a resume at source timestamp 617.3.
        let audio = 600.0
        let video = 610.0

        // Act — evaluate the same startup correction used by the combined demux loop.
        let correction = SWClockAnchorPolicy.startupAVSkewCorrection(
            initialSeconds: 617.3,
            firstAudioSampleSeconds: audio,
            firstVideoSampleSeconds: video
        )

        // Assert — preroll must never replace the requested resume anchor.
        #expect(correction == nil)
    }

    /// Both startup corrections preserve the session axis established before an offset resume.
    @Test("a clock re-anchor after an offset-origin resume keeps its source origin")
    func test_reanchoredSessionZero_offsetResume_preservesRequestedPosition() throws {
        // Arrange — a source starting at 600 resumes at session 17.3 with audio preroll.
        let requestedPosition = 17.3
        let initialZero = SWClockAnchorPolicy.resumeSessionZero(sourceOriginSeconds: 600)
        let sourceAnchor = SWClockAnchorPolicy.sourceSeconds(
            forSession: requestedPosition,
            sessionZeroSeconds: initialZero
        )
        let correction = try #require(
            SWClockAnchorPolicy.startupAVSkewCorrection(
                initialSeconds: sourceAnchor,
                firstAudioSampleSeconds: 610,
                firstVideoSampleSeconds: 618
            )
        )
        let aheadSample = SWClockAnchorPolicy.resolve(
            initialSeconds: sourceAnchor,
            firstSampleSeconds: 621
        )

        // Act — compose each re-anchor with the origin captured at load time.
        for resolution in [correction.clockResolution, aheadSample] {
            let sessionZero = SWClockAnchorPolicy.reanchoredSessionZero(
                initialSessionZeroSeconds: initialZero,
                additionalOffsetSeconds: resolution.sessionZeroSeconds
            )
            let publishedPosition = resolution.anchorSeconds - sessionZero

            // Assert — both paths still publish the requested resume position.
            #expect(abs(publishedPosition - requestedPosition) < 1e-9)
            #expect(abs(SWClockAnchorPolicy.sourceSeconds(
                forSession: requestedPosition,
                sessionZeroSeconds: sessionZero
            ) - resolution.anchorSeconds) < 1e-9)
        }
    }

    // MARK: - Carrying a seek target back to the source axis

    @Test("a zero-based source seeks on the axis it already uses")
    func sourceSecondsIsIdentityWithoutAnOffset() {
        #expect(SWClockAnchorPolicy.sourceSeconds(forSession: 35.29, sessionZeroSeconds: 0) == 35.29)
        #expect(SWClockAnchorPolicy.sourceSeconds(forSession: 0, sessionZeroSeconds: 0) == 0)
    }

    @Test("a mid-stream-joined source seeks past its own first packet, not before it")
    func sourceSecondsCarriesTheOffset() {
        // The capture that found this: first PTS 24549.835 s, a 64 s file, and a
        // seek to 35.29 s of session time. Without the carry the demuxer is asked
        // for a timestamp six hours before the file begins and clamps to its start,
        // and the packet store's reservoir reads as the whole offset.
        let target = SWClockAnchorPolicy.sourceSeconds(
            forSession: 35.29,
            sessionZeroSeconds: 24_549.835
        )
        #expect(target == 24_585.125)
    }

    @Test("the carry is the inverse of the position the host publishes")
    func sourceSecondsRoundTripsThePublishedPosition() {
        let zero = 24_549.835
        for session in [0.0, 1.0, 35.29, 64.564] {
            let raw = SWClockAnchorPolicy.sourceSeconds(forSession: session, sessionZeroSeconds: zero)
            // `SoftwarePlaybackHost` publishes `max(0, raw - zero)`.
            #expect(abs(max(0, raw - zero) - session) < 1e-9)
        }
    }

    @Test("a target that cannot be expressed is passed through rather than made worse")
    func sourceSecondsRefusesNonsense() {
        #expect(SWClockAnchorPolicy.sourceSeconds(forSession: 10, sessionZeroSeconds: -5) == 10)
        #expect(SWClockAnchorPolicy.sourceSeconds(forSession: 10, sessionZeroSeconds: .nan) == 10)
        #expect(SWClockAnchorPolicy.sourceSeconds(forSession: .infinity, sessionZeroSeconds: 100).isInfinite)
    }
}
