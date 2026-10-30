import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// Exercises the public correction against actual Live producers and their delivered fMP4 audio.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct LiveAudioDelayTests {
    // Failure modes:
    // - The setter changes only a requested value, leaving the active producer unchanged.
    // - An old source teardown resumes after stop or replacement and reopens a retired session.
    // - Changes during a rebuild lose the latest delay or play/pause intent.

    /// Loads deterministic H.264/AAC media through the real native Live pipeline without DVR.
    private func withLiveEngine(
        _ body: (AetherEngine, URL) async throws -> Void
    ) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-audio-delay-\(UUID().uuidString).ts")
        try LongGOPTransportStreamFixture.data().write(to: url)
        let engine = try AetherEngine()
        defer {
            engine.stop()
            try? FileManager.default.removeItem(at: url)
        }
        try await engine.load(url: url, options: LoadOptions(isLive: true, autoplay: false))
        try await waitFor { engine.state == .paused }
        try #require(engine.videoRoute == .loopback)
        try #require(!engine.audioTracks.isEmpty)
        try #require(engine.liveWindow?.windowSeconds == nil)
        try await body(engine, url)
    }

    /// Measures actual packet PTS in a resident segment beyond the initial timestamp clamp.
    private func audioVideoOffset(_ engine: AetherEngine) async throws -> Double {
        let session = try #require(engine.nativeVideoSession)
        try await waitFor { session.scrubThumbnailSource(atSeconds: 10.1) != nil }
        let source = try #require(session.scrubThumbnailSource(atSeconds: 10.1))
        let reader = try #require(source.makeReader())
        let job = ProbeTestJob<Double> {
            let demuxer = Demuxer()
            defer { demuxer.close() }
            try demuxer.open(reader: reader, formatHint: "mp4")
            var audio: Double?
            var video: Double?
            while let packet = try demuxer.readPacket() {
                defer {
                    var owned = Optional(packet)
                    av_packet_free(&owned)
                }
                let stream = try #require(demuxer.stream(at: packet.pointee.stream_index))
                let timeBase = stream.pointee.time_base
                let seconds = Double(packet.pointee.pts) * Double(timeBase.num) / Double(timeBase.den)
                if packet.pointee.stream_index == demuxer.audioStreamIndex, audio == nil { audio = seconds }
                if packet.pointee.stream_index == demuxer.videoStreamIndex, video == nil { video = seconds }
                if let audio, let video { return audio - video }
            }
            throw CocoaError(.fileReadCorruptFile)
        }
        return try await job.outcome().get()
    }

    /// Both signs and reset-to-zero must reach newly delivered timestamps, with DVR still disabled.
    @Test
    func runtimeChangesRetimestampLiveAudio() async throws {
        try await withLiveEngine { engine, _ in
            let baseline = try await audioVideoOffset(engine)
            let audioTrack = engine.activeAudioTrackIndex
            for delay in [0.5, -0.5, 0] {
                let previous = try #require(engine.nativeVideoSession)
                engine.setAudioDelay(delay)
                try await waitFor { engine.nativeVideoSession != nil && engine.nativeVideoSession !== previous }
                try await waitFor { engine.state == .paused }
                let actual = try await audioVideoOffset(engine)
                #expect(abs(actual - baseline - delay) < 0.025)
                #expect(engine.liveWindow?.windowSeconds == nil)
                #expect(engine.nativeHost?.transportIntentIsPlaying == false)
                #expect(engine.activeAudioTrackIndex == audioTrack)
            }
        }
    }

    /// A forward-only source with no factory stays alive and explicitly reports the refusal.
    @Test
    func nonReopenableCustomLiveSourceIsRefusedWithoutTeardown() async throws {
        let reader = ForwardOnlyMediaReader(data: try LongGOPTransportStreamFixture.data())
        let engine = try AetherEngine()
        let messages = ProbeTestBox<[String]>([])
        let previousHandler = EngineLog.handler
        EngineLog.handler = { line in
            messages.update { $0.append(line) }
        }
        defer { engine.stop(); EngineLog.handler = previousHandler }
        try await engine.load(source: .custom(reader, formatHint: "mpegts"),
                              options: LoadOptions(isLive: true, autoplay: false))
        try await waitFor { engine.state == .paused }
        try #require(engine.videoRoute == .loopback)
        let previous = try #require(engine.nativeVideoSession)
        let baseline = try await audioVideoOffset(engine)

        engine.setAudioDelay(0.5)

        #expect(engine.nativeVideoSession === previous)
        #expect(engine.liveAudioDelayRejoinTask == nil)
        #expect(reader.closeCount == 0)
        #expect(engine.audioDelaySeconds == 0.5)
        #expect(messages.value.contains { $0.contains("Audio-delay rebuild refused (customSourceNotSeekable)") })
        let actual = try await audioVideoOffset(engine)
        #expect(abs(actual - baseline) < 0.001)
    }

    /// Holds the real detached cleanup before source close, without blocking the main actor.
    private func holdTeardown(_ session: HLSVideoEngine) -> ProbeTestGate {
        let gate = ProbeTestGate()
        session.onSessionCacheStatusChanged = { status in
            if status.cleanupReason != nil { gate.wait() }
        }
        return gate
    }

    /// New source work may not start while the prior cleanup is held; all changes converge afterward.
    @Test
    func burstChangesPreserveLatestDelayAndTransport() async throws {
        try await withLiveEngine { engine, _ in
            let baseline = try await audioVideoOffset(engine)
            let previous = try #require(engine.nativeVideoSession)
            let gate = holdTeardown(previous)
            defer { gate.open() }
            engine.setAudioDelay(0.5)
            try await waitFor { gate.entered }
            #expect(engine.nativeVideoSession == nil)
            #expect(engine.state == .loading)

            engine.play()
            engine.setAudioDelay(-0.25)
            engine.pause()
            engine.setAudioDelay(-0.5)
            engine.play()
            gate.open()

            try await waitFor { engine.liveAudioDelayRejoinTask == nil }
            try await waitFor { engine.state == .playing }
            let actual = try await audioVideoOffset(engine)
            #expect(abs(actual - baseline + 0.5) < 0.025)
            #expect(engine.nativeHost?.transportIntentIsPlaying == true)
            #expect(engine.liveWindow?.windowSeconds == nil)
            try await waitFor { engine.currentTime > 0.1 }
        }
    }

    /// Neither an explicit stop nor another load can be revived by a late teardown completion.
    @Test(arguments: [false, true])
    func retiringSessionDuringTeardownCannotReopen(replaceSource: Bool) async throws {
        try await withLiveEngine { engine, url in
            let gate = holdTeardown(try #require(engine.nativeVideoSession))
            defer { gate.open() }
            engine.setAudioDelay(0.5)
            try await waitFor { gate.entered }
            let retiredCorrection = engine.liveAudioDelayRejoinTask
            let replacementURL = url.deletingLastPathComponent()
                .appendingPathComponent("replacement-\(UUID().uuidString).ts")
            defer { try? FileManager.default.removeItem(at: replacementURL) }
            var replacement: HLSVideoEngine?
            if replaceSource {
                try FileManager.default.copyItem(at: url, to: replacementURL)
                try await engine.load(url: replacementURL, options: LoadOptions(isLive: true, autoplay: false))
                try await waitFor { engine.state == .paused }
                replacement = try #require(engine.nativeVideoSession)
            } else {
                engine.stop()
            }
            gate.open()
            await retiredCorrection?.value

            #expect(engine.liveAudioDelayRejoinTask == nil)
            if replaceSource {
                #expect(engine.audioDelaySeconds == 0)
                #expect(engine.nativeVideoSession === replacement)
                #expect(engine.state == .paused)
            } else {
                #expect(engine.audioDelaySeconds == 0.5)
                #expect(engine.nativeVideoSession == nil)
                #expect(engine.state == .idle)
            }
        }
    }

    /// A large correction blocked waiting for future source history is obsolete as soon as reset
    /// or the opposite sign is requested. Reopening the same source must not await its 180 s warmup.
    @Test
    func zeroInterruptsObsoleteLargeWarmup() async throws {
        try await verifyObsoleteLargeWarmup(latest: 0)
    }

    /// Opposite-sign requests preempt the captured positive history before a later zero reset.
    @Test
    func oppositeSignInterruptsObsoleteLargeWarmup() async throws {
        try await verifyObsoleteLargeWarmup(latest: -180)
    }

    /// A graph captured before a 180-second warmup is preempted through the existing source barrier.
    @Test
    func shapingInterruptsCapturedLargeWarmup() async throws {
        try await verifyObsoleteLargeWarmup(latest: 0,
            shaping: AudioShaping(dialogueGainDB: 6, compressor: .night))
    }

    /// Drives a real HLS producer after option capture, with its outgoing source close held.
    private func verifyObsoleteLargeWarmup(latest: Double, shaping: AudioShaping? = nil) async throws {
        let origin = try #require(RangeFilesOrigin())
        defer { origin.stop() }
        origin.serve("/head.ts", try LongGOPTransportStreamFixture.data(), contentType: "video/mp2t")
        origin.serve("/live.m3u8", Data("""
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:32
            #EXT-X-MEDIA-SEQUENCE:0
            #EXTINF:32,
            head.ts

            """.utf8), contentType: "application/vnd.apple.mpegurl")
        let sidecar = FileManager.default.temporaryDirectory.appendingPathComponent("delay-selection-\(UUID()).vtt")
        try Data("WEBVTT\n\n00:00.000 --> 01:30.000\nSelection during warmup\n".utf8).write(to: sidecar)
        defer { try? FileManager.default.removeItem(at: sidecar) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let url = try #require(URL(string: origin.baseURL + "/live.m3u8"))
        try await engine.load(url: url, options: LoadOptions(isLive: true,
            liveJoinProfile: .fastZap, liveStartupGraceSeconds: 0.1,
            liveStartupSingleSegmentMinimumSeconds: 0.1, liveEdgeCushionSeconds: 0.5,
            maxConcurrentSourceRequests: 1, autoplay: false))
        try await waitFor { engine.state == .paused }
        let selected = engine.activeAudioTrackIndex
        let initial = try #require(engine.nativeVideoSession)
        engine.setAudioDelay(180)
        try #require(try await waitFor(upTo: .seconds(8)) {
            engine.nativeVideoSession !== initial && engine.nativeVideoSession?.audioDelaySeconds == 180
                && origin.requests(to: "/head.ts").count >= 2
        })
        #expect(!engine.isSessionReady, "32 s of source cannot satisfy a 180 s warmup")
        engine.selectSidecarSubtitle(url: sidecar)
        try #require(try await waitFor(upTo: .seconds(3)) { engine.loadedSidecarURL == sidecar && engine.isSubtitleActive })
        let obsolete = try #require(engine.nativeVideoSession)
        let owner = engine.liveAudioDelayRejoinID
        let barrier = holdTeardown(obsolete)
        defer { barrier.open() }
        engine.play()
        engine.pause()
        if let shaping { engine.setAudioShaping(shaping) }
        else { engine.setAudioDelay(latest) }
        try #require(engine.liveAudioDelayRejoinID != owner)
        try #require(try await waitFor(upTo: .seconds(5)) { barrier.entered })
        let requestsAtBarrier = origin.requests.count
        #expect(!engine.needsForegroundVideoRestore)
        engine.play()
        engine.pause()
        try await Task.sleep(for: .milliseconds(150))
        #expect(origin.requests.count == requestsAtBarrier,
            "Successor load's second teardown must retain the interrupted source-close barrier")
        #expect(engine.nativeVideoSession == nil)
        if shaping != nil { engine.setAudioDelay(latest) }
        barrier.open()
        try #require(try await waitFor(upTo: .seconds(8)) {
            engine.nativeVideoSession != nil && engine.nativeVideoSession !== obsolete
                && engine.nativeVideoSession?.audioDelaySeconds == latest
        })
        if latest != 0 {
            // The unchanged Live manifest withholds the future interval. Resetting again
            // proves a second generation can supersede the first without a stale owner's cleanup.
            engine.clearSubtitle()
            engine.setAudioDelay(0)
        }
        // This one-segment upstream has an independent first-window grace. The new producer must
        // be installed within8 s above; allow that existing startup policy to settle afterward.
        try #require(try await waitFor(upTo: .seconds(40)) {
            engine.liveAudioDelayRejoinTask == nil && engine.state == .paused
        })
        #expect(engine.audioDelaySeconds == 0)
        if let shaping {
            #expect(engine.nativeVideoSession?.audioShaping == shaping)
            #expect(engine.audioShapingState == .applied)
        }
        #expect(!engine.sessionPreservingReloadInFlight)
        #expect(!engine.needsForegroundVideoRestore)
        #expect(engine.loadedSidecarURL == (latest == 0 ? sidecar : nil))
        #expect(engine.isSubtitleActive == (latest == 0))
        #expect(engine.activeAudioTrackIndex == selected)
        #expect(engine.nativeHost?.transportIntentIsPlaying == false)
        #expect(engine.liveWindow?.windowSeconds == nil)
        engine.play()
        try #require(try await waitFor(upTo: .seconds(5)) { engine.currentTime > 0.1 })
    }

    /// Normal Live HLS auto-ingest can rejoin despite its forward-only byte interface. Current
    /// headers, including User-Agent, reach the fresh reader, with no request before old teardown.
    @Test
    func hlsIngestRejoinsWithCurrentHeadersAfterSourceTeardown() async throws {
        let origin = try #require(RangeFilesOrigin())
        let bytes = try LongGOPTransportStreamFixture.data()
        origin.serve("/live.ts", bytes, contentType: "video/mp2t")
        origin.serve("/live.m3u8", Data("""
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:32
            #EXT-X-MEDIA-SEQUENCE:0
            #EXTINF:32,
            live.ts

            """.utf8), contentType: "application/vnd.apple.mpegurl")
        let engine = try AetherEngine()
        defer { engine.stop(); origin.stop() }
        let url = try #require(URL(string: origin.baseURL + "/live.m3u8"))
        try await engine.load(url: url, options: LoadOptions(
            httpHeaders: ["X-Delay-Test": "initial", "User-Agent": "AetherDelayRegression/1"],
            isLive: true, maxConcurrentSourceRequests: 1, autoplay: false
        ))
        try await waitFor { engine.state == .paused }
        try #require(engine.videoRoute == .loopback)
        try #require(!engine.customSourceIsSeekable)
        let baseline = try await audioVideoOffset(engine)
        let previous = try #require(engine.nativeVideoSession)
        let gate = holdTeardown(previous)
        defer { gate.open() }
        engine.updateRequestHeaders(["X-Delay-Test": "current", "User-Agent": "AetherDelayRegression/2"])
        let requestCount = origin.requests.count
        engine.setAudioDelay(0.5)
        try await waitFor { gate.entered }
        #expect(engine.nativeVideoSession == nil)
        #expect(origin.requests.count == requestCount, "Replacement source must wait for old source teardown")
        gate.open()
        try await waitFor { engine.liveAudioDelayRejoinTask == nil }
        try await waitFor { engine.state == .paused }

        let actual = try await audioVideoOffset(engine)
        #expect(abs(actual - baseline - 0.5) < 0.025)
        let freshRequests = Array(origin.requests.dropFirst(requestCount))
        #expect(!freshRequests.isEmpty)
        #expect(freshRequests.allSatisfy { $0.headers["x-delay-test"] == "current" })
        #expect(freshRequests.allSatisfy { $0.headers["user-agent"] == "AetherDelayRegression/2" })
        #expect(engine.liveWindow?.windowSeconds == nil)
        #expect(engine.nativeHost?.transportIntentIsPlaying == false)
    }
}
