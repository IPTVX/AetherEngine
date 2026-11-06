import Foundation
import Testing
@testable import AetherEngine

/// Exercises the optional reader with a future keyframe and decodes its result through the same
/// resident extractor used by the public scrub API; ordinary I-frame serving stays unrequested.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct IPTVXBackgroundScrubConsentTests {
    /// Without consent no elective source can be made; with consent its later keyframe yields an
    /// actual image and cancellation still suppresses delivery to a replaced scrub request.
    @Test(.offCooperativePool)
    func test_futureKeyframe_withConsent_decodesAndHonorsCancellation() async throws {
        // Arrange
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iptvx-consent-\(UUID()).mp4")
        try ScrubLadderFixture.data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // Act
        for enabled in [false, true] {
            let session = HLSVideoEngine(url: url, dvModeAvailable: false)
            session.generatesBackgroundScrubPreviews = enabled
            _ = try session.start()
            defer { session.stop() }
            let plan = session.segmentPlan
            let optionalSource = session.makeStillLadderSource(plan: plan)

            // Assert
            if !enabled {
                #expect(optionalSource == nil)
                continue
            }
            let source = try #require(optionalSource)
            let index = try #require(plan.indices.last)
            #expect(plan[index].startSeconds > 0)
            let payload = try #require(source.keyframes.keyframePayload(at: index))
            let fragment = try #require(source.builder.build(
                payload: payload,
                durationSeconds: plan[index].durationSeconds
            ))
            let extractor = FrameExtractor(
                residentReader: DataIOReader(parts: [fragment.initSegment, fragment.fragment]),
                formatHint: "mp4",
                identity: "consented-future-keyframe"
            )
            let frame = try #require(await extractor.residentPreview(
                rawTarget: 0,
                refined: false,
                maxWidth: 64,
                isCancelled: { false }
            ))
            #expect(frame.image.width > 0 && frame.image.width <= 64)
            #expect(!frame.refined)
            #expect(await extractor.residentPreview(
                rawTarget: 0,
                refined: false,
                maxWidth: 64,
                isCancelled: { true }
            ) == nil)
        }
    }
}
