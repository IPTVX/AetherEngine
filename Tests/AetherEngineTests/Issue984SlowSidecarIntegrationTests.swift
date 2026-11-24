import AVFoundation
import Foundation
import Testing
@testable import AetherEngine

/// Real loopback HLS playback must remain independent of a selected sidecar's minute-long response.
@Suite(.serialized, .timeLimit(.minutes(4)))
@MainActor
struct Issue984SlowSidecarIntegrationTests {
    // Failure modes:
    // - Selected sidecar I/O blocks main-item readiness at load or stalls an already playing item.
    // - The UI pick disappears while pending, or AVPlayer receives an unfinished rendition.
    // - Proxy media or same-origin sidecar fetches lose the caller's authentication headers.
    /// Both selection entry points publish the pick immediately while actual network I/O stays pending.
    @Test(arguments: [true, false])
    func test_selectedSidecar_sixtySecondResponse_doesNotBlockNativePlayback(
        selectedAtLoad: Bool
    ) async throws {
        // Arrange
        let origin = try #require(RangeFilesOrigin())
        defer { origin.stop() }
        let segment = try LongGOPTransportStreamFixture.data()
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nmedia.m3u8\n"
        var media = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:33\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        for index in 0..<8 {
            // Each synthetic closed-GOP segment restarts its timestamps, so declare the boundary.
            if index > 0 { media += "#EXT-X-DISCONTINUITY\n" }
            media += "#EXTINF:32.04,\nsegment\(index).ts\n"
            origin.serve("/segment\(index).ts", segment, contentType: "video/mp2t")
        }
        media += "#EXT-X-ENDLIST\n"
        origin.serve("/master.m3u8", Data(master.utf8), contentType: "application/vnd.apple.mpegurl")
        origin.serve("/media.m3u8", Data(media.utf8), contentType: "application/vnd.apple.mpegurl")
        origin.serve("/slow.vtt", Data("WEBVTT\n\n00:00:00.000 --> 00:04:00.000\nDelayed English\n".utf8),
                     contentType: "text/vtt")
        let responseGate = origin.holdResponses(for: "/slow.vtt")
        defer { responseGate.open() }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let trackID = AetherEngine.externalSubtitleTrackIDBase
        let headers = ["Authorization": "Bearer synthetic-fixture-token", "User-Agent": "AetherSidecarFixture/1"]
        var options = LoadOptions(
            httpHeaders: headers,
            nativeRemoteHLS: true,
            externalSubtitles: [ExternalSubtitleTrack(
                url: try #require(URL(string: origin.baseURL + "/slow.vtt")),
                name: "Delayed English", language: "en"
            )],
            autoplay: true
        )
        options.initialSubtitleTrackID = selectedAtLoad ? trackID : nil

        // Act
        try await engine.load(url: try #require(URL(string: origin.baseURL + "/master.m3u8")), options: options)
        let host = try #require(engine.nativeHost)
        let item = try #require(host.avPlayer.currentItem)
        item.preferredForwardBufferDuration = 1
        let provider = try #require(engine.remoteHLSSubtitleProxy?.provider)
        let ready = try await waitFor(upTo: .seconds(15)) {
            item.status == .readyToPlay && host.avPlayer.currentTime().seconds > 0.2 || engine.errorInfo != nil
        }
        try #require(ready && item.status == .readyToPlay,
                     "Native loopback HLS must become ready while its selected sidecar is held; error=\(String(describing: engine.errorInfo))")
        if !selectedAtLoad { engine.selectSubtitleTrack(index: trackID) }
        #expect(engine.activeSubtitleTrackIndex == trackID)
        try await waitFor { responseGate.entered }
        let legible = try #require(try await item.asset.loadMediaSelectionGroup(for: .legible))
        let heldAt = ContinuousClock.now
        let startTime = host.avPlayer.currentTime().seconds

        // Assert — this is sixty actual seconds of pending network I/O, with the main player running.
        while ContinuousClock.now - heldAt < .seconds(60) {
            try #require(engine.activeSubtitleTrackIndex == trackID)
            #expect(provider.renditionServe(ordinal: 0) == .retryLater)
            #expect(item.currentMediaSelection.selectedMediaOption(in: legible) == nil)
            #expect(host.avPlayer.currentItem === item)
            #expect(engine.errorInfo == nil)
            try await Task.sleep(for: .seconds(1))
        }
        #expect(host.avPlayer.currentTime().seconds > startTime + 40,
                "A minute-long sidecar response must leave the main item advancing")
        let sidecarRequests = origin.requests(to: "/slow.vtt")
        #expect(!sidecarRequests.isEmpty)
        #expect(sidecarRequests.allSatisfy { $0.headers["authorization"] == headers["Authorization"] })
        #expect(sidecarRequests.allSatisfy { $0.headers["user-agent"] == headers["User-Agent"] })
        let mediaRequests = origin.requests.filter { $0.path.hasSuffix(".ts") }
        #expect(!mediaRequests.isEmpty)
        #expect(mediaRequests.allSatisfy { $0.headers["authorization"] == headers["Authorization"] })

        // Act — only a completed sidecar may now be handed to AVPlayer.
        responseGate.open()
        try await waitFor { provider.renditionServe(ordinal: 0) == .complete || engine.errorInfo != nil }
        try await waitFor { item.currentMediaSelection.selectedMediaOption(in: legible) != nil || engine.errorInfo != nil }

        // Assert
        #expect(engine.errorInfo == nil)
        #expect(engine.activeSubtitleTrackIndex == trackID)
        #expect(item.currentMediaSelection.selectedMediaOption(in: legible)?.displayName == "Delayed English")
    }
}
