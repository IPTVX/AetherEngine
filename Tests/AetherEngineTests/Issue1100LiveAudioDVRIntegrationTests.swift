import Foundation
import Testing
@testable import AetherEngine

/// Exercises the real software ring, decoders and renderer when audio changes behind the live edge.
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct Issue1100LiveAudioDVRIntegrationTests {
    // Failure modes:
    // - An audio pick reopens the source and rejoins live instead of retaining the DVR playhead.
    // - A successful pick drops canSeek or the resident rewind window.
    // - The new track is reported selected but no audio reaches the renderer after reseeding.

    /// A paused DVR seek followed by an audio pick keeps the source, position and usable rewind history.
    @Test
    func audioSwitchBehindLiveKeepsSourcePositionAndSeekability() async throws {
        // Arrange
        let reader = ProbeLiveTailReader(data: TwoAudioTrackFixture.data)
        let engine = try AetherEngine()
        let deliveredAudio = ProbeTestBox(0)
        defer {
            reader.release()
            engine.stop()
        }
        engine.softwareHostLoadedForTesting = { host in
            // A Live tail stays open while its already delivered packets remain available for rewind.
            reader.arm()
            host.observeDeliveredAudioForTesting { deliveredAudio.update { $0 += 1 } }
        }
        var options = LoadOptions(isLive: true, autoplay: false, preferredDecodePath: .software)
        options.dvrWindowSeconds = 30
        // The finite fixture must not latch AVIO EOF during the stream-info probe.
        options.maxAnalyzeDuration = 100_000
        try await engine.load(source: .custom(reader, formatHint: "matroska"), options: options)
        let host = try #require(engine.softwareHost)
        try await waitFor {
            (engine.canSeek && reader.isBlocked && engine.state == .paused)
                || engine.errorInfo != nil
        }
        try #require(engine.errorInfo == nil)
        try #require(!host.liveSourceEndForTesting.hasEnded)
        let range = try #require(engine.seekableLiveRange)
        try #require(range.upperBound - range.lowerBound >= 4)
        let target = range.lowerBound + 1.5
        await engine.seek(to: target, exact: true)
        try await waitFor { !engine.isSeeking || engine.errorInfo != nil }
        try #require(engine.errorInfo == nil)
        try #require(abs(engine.currentTime - target) < 0.6)
        let selectedTrack = try #require(engine.audioTracks.first { $0.id != engine.activeAudioTrackIndex })
        try #require(host.canSwitchLiveAudioInPlace(to: Int32(selectedTrack.id)))
        let generation = engine.loadGeneration
        let readerCancellations = reader.cancellationCount
        let readerSeeks = reader.seekCount
        let readerCloses = reader.closeCount
        let edge = engine.liveEdgeTime
        let deliveredBeforeSwitch = deliveredAudio.value

        // Act
        engine.selectAudioTrack(index: selectedTrack.id)
        try await waitFor { engine.activeAudioTrackIndex == selectedTrack.id || engine.errorInfo != nil }

        // Assert
        try #require(engine.errorInfo == nil)
        #expect(engine.softwareHost === host)
        #expect(engine.loadGeneration == generation)
        #expect(reader.cancellationCount == readerCancellations)
        #expect(reader.seekCount == readerSeeks)
        #expect(reader.closeCount == readerCloses)
        #expect(reader.isBlocked)
        #expect(!host.liveSourceEndForTesting.hasEnded)
        #expect(engine.state == .paused)
        #expect(engine.canSeek)
        #expect(abs(engine.currentTime - target) < 0.6)
        #expect(engine.currentTime < edge - 1)
        #expect(engine.seekableLiveRange?.contains(target) == true)

        // Reseeding a paused mount may already enqueue the new audio before selectAudioTrack returns.
        // Measure from before the switch, then verify playback advances through that queued output.
        let pausedPosition = engine.currentTime
        engine.play()
        try await waitFor {
            (deliveredAudio.value >= deliveredBeforeSwitch + 4 && engine.currentTime > pausedPosition + 0.2)
                || engine.errorInfo != nil
        }
        #expect(engine.errorInfo == nil)
        #expect(deliveredAudio.value >= deliveredBeforeSwitch + 4)
        #expect(engine.softwareHost === host)
        #expect(engine.loadGeneration == generation)
        #expect(engine.activeAudioTrackIndex == selectedTrack.id)
        #expect(engine.canSeek)
        #expect(engine.currentTime < edge - 0.5)
    }
}
