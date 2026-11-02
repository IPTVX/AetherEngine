import Foundation
import Testing
@testable import AetherEngine

/// Verifies that the upstream direct Live reader and retained large-delay alignment never share source ownership.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct DirectLiveAudioDelayRoutingTests {
    // Failure modes:
    // - Large offsets start both the forward-only worker and compressed alignment on one demuxer.
    // - Returning to a small offset reuses a retired worker or exposes a DVR window.
    // - A small offset update needlessly replaces the ordinary Live source.

    /// Runtime boundary crossings retire the previous source while preserving paused Live intent.
    @Test
    func test_audioDelay_crossingAlignmentBoundary_preservesExclusiveSourceOwnership() async throws {
        // Arrange — a seekable source can provide the complete retained +/-180-second range.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("public-live-delay-\(UUID()).ts")
        try await BlockingWork.detached(priority: .userInitiated) {
            try LongAudioDelayTransportStreamFixture.write(to: url)
        }.value
        let engine = try AetherEngine()
        defer {
            engine.stop()
            try? FileManager.default.removeItem(at: url)
        }
        try await engine.load(
            url: url,
            options: LoadOptions(
                isLive: true,
                autoplay: false,
                audioDelaySeconds: 0.5,
                preferredDecodePath: .software
            )
        )
        let initial = try #require(engine.softwareHost?.directLiveReadAheadForTesting)

        // Act — cross both large-offset signs, then return to the ordinary Live route.
        engine.setAudioDelay(2)
        #expect(engine.softwareHost?.directLiveReadAheadForTesting === initial)
        for delay in [180.0, -180.0, -2.0, 0.0] {
            engine.setAudioDelay(delay)
            try #require(try await waitFor(upTo: .seconds(10)) {
                engine.liveAudioDelayRejoinTask == nil && engine.state == .paused
            })
            #expect(engine.errorInfo == nil)
            #expect(engine.audioDelaySeconds == delay)
            #expect(engine.liveWindow?.windowSeconds == nil)
            #expect((engine.softwareHost?.directLiveReadAheadForTesting != nil) == (abs(delay) <= 2))
        }

        // Assert — no retired producer can continue owning the source after the first boundary crossing.
        #expect(throws: SoftwarePacketReadAhead.ReadError.closed) {
            _ = try initial.packets.read(maximumWait: 0)
        }
    }
}
