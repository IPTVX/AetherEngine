import Foundation
import AVFoundation
import Testing
@testable import AetherEngine

/// Exercises the actual native engine route, including finite boundary gaps and public seeking.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct NativeLargeAudioDelayTests {
    /// Opt-in, existing public SMBClient sample; no provider/user media or machine path enters Git.
    private static var physicalFixtureURL: URL? {
        let environment = ProcessInfo.processInfo.environment
        return (environment["AETHER_NATIVE_DELAY_FIXTURE"] ?? environment["TEST_RUNNER_AETHER_NATIVE_DELAY_FIXTURE"])
            .map { URL(fileURLWithPath: $0) }
    }

    /// Waits for actual clock progress while surfacing a native pipeline error at its source.
    private func progress(_ engine: AetherEngine, beyond position: Double) async throws {
        try #require(try await waitFor(upTo: .seconds(10)) {
            if case .error = engine.state { return true }
            return engine.isSessionReady && engine.currentTime > position
        })
        if case .error(let message) = engine.state { Issue.record("Native audio-delay playback failed: \(message)") }
        try #require(engine.currentTime > position)
    }

    /// Polls actual decoded frames after asynchronous item handover rather than mistaking a Live
    /// clock-axis adjustment for rendered motion.
    private func decodedProgress(_ engine: AetherEngine, output initialOutput: AVPlayerItemVideoOutput) async throws {
        var currentOutput = initialOutput
        var observedItem: AVPlayerItem?
        var first: Double?
        defer { observedItem?.remove(currentOutput) }
        try #require(try await waitFor(upTo: .seconds(8)) {
            guard let item = engine.currentAVPlayer?.currentItem else { return false }
            if observedItem !== item {
                observedItem?.remove(currentOutput)
                currentOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
                item.add(currentOutput)
                observedItem = item
                first = nil
            }
            var displayed = CMTime.invalid
            guard currentOutput.copyPixelBuffer(forItemTime: engine.currentAVPlayer!.currentTime(), itemTimeForDisplay: &displayed) != nil,
                  displayed.seconds.isFinite else { return false }
            if let first { return displayed.seconds > first + 0.1 }
            first = displayed.seconds
            return false
        })
    }

    /// Larger offsets retain native decode, decoded video and the selected finite video position.
    @Test(.enabled(if: (ProcessInfo.processInfo.environment["AETHER_NATIVE_DELAY_FIXTURE"]
                    ?? ProcessInfo.processInfo.environment["TEST_RUNNER_AETHER_NATIVE_DELAY_FIXTURE"]) != nil,
                   "Requires the documented public native hardware-size fixture"),
          arguments: [180.0, -180.0, 2.5, -2.5, 3.0, -3.0, 30.0, -30.0])
    func actualNativePlaybackAndSeek(delay: Double) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-delay-\(UUID()).mp4")
        let titleDuration = try IndexedAudioDelayFixture.write(to: url, repetitions: 2,
            inputURL: try #require(Self.physicalFixtureURL))
        let engine = try AetherEngine()
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        try await engine.load(url: url, options: LoadOptions(sessionCacheByteBudget: 256 << 20, autoplay: true, audioDelaySeconds: delay))
        try #require(engine.videoRoute == .loopback)
        let item = try #require(engine.currentAVPlayer?.currentItem)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        try await progress(engine, beyond: 0.3)
        #expect(engine.currentTime < 1.5, "A positive delay must not skip the opening video")
        #expect(output.copyPixelBuffer(forItemTime: engine.currentAVPlayer!.currentTime(), itemTimeForDisplay: nil) != nil)
        print("NATIVE_LARGE delay=\(delay) initial=\(engine.currentTime) item=\(engine.currentAVPlayer!.currentTime().seconds) route=\(engine.videoRoute)")
        if delay == 30 {
            await engine.seek(to: 29.5)
            try await progress(engine, beyond: 29.6)
            #expect(engine.currentTime < 30.3, "A seek inside the opening audio gap retains video position")
            #expect(output.copyPixelBuffer(forItemTime: engine.currentAVPlayer!.currentTime(), itemTimeForDisplay: nil) != nil)
        }
        let tailPosition = titleDuration - 1
        await engine.seek(to: tailPosition)
        try await progress(engine, beyond: tailPosition + 0.1)
        #expect(output.copyPixelBuffer(forItemTime: engine.currentAVPlayer!.currentTime(), itemTimeForDisplay: nil) != nil)
        print("NATIVE_LARGE delay=\(delay) seekProgress=\(engine.currentTime) state=\(engine.state)")
    }

    /// Large offsets on realistic source duration must retain decoded native video and public
    /// VOD position, or perform a bounded compressed fresh-edge warmup for Live without DVR.
    @Test(.enabled(if: (ProcessInfo.processInfo.environment["AETHER_NATIVE_DELAY_FIXTURE"]
                    ?? ProcessInfo.processInfo.environment["TEST_RUNNER_AETHER_NATIVE_DELAY_FIXTURE"]) != nil,
                   "Requires the documented public native hardware-size fixture"),
          arguments: [180.0, -180.0], [false, true])
    func fullDurationPlayback(delay: Double, live: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-long-delay-\(UUID()).mp4")
        let titleDuration = try IndexedAudioDelayFixture.write(to: url, repetitions: 8,
            inputURL: live ? nil : try #require(Self.physicalFixtureURL))
        let engine = try AetherEngine()
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        try await engine.load(url: url, options: LoadOptions(isLive: live,
            sessionCacheByteBudget: 256 << 20, autoplay: true, audioDelaySeconds: delay))
        try #require(engine.videoRoute == .loopback)
        let item = try #require(engine.currentAVPlayer?.currentItem)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        try #require(try await waitFor(upTo: .seconds(10)) { engine.currentAVPlayer!.currentTime().seconds > 0.3 })
        let observed = engine.currentTime
        try await progress(engine, beyond: observed + 0.2)
        try await decodedProgress(engine, output: output)
        if live { #expect(engine.liveWindow?.windowSeconds == nil) }
        else {
            #expect(engine.currentTime < 1.5)
            if delay > 0 {
                for target in [90.0, 179.5] {
                    await engine.seek(to: target)
                    try await progress(engine, beyond: target + 0.1)
                    #expect(engine.currentTime < target + 0.8, "Leading gaps must not move a finite video seek to its first audio")
                    #expect(output.copyPixelBuffer(forItemTime: engine.currentAVPlayer!.currentTime(), itemTimeForDisplay: nil) != nil)
                }
            }
            if delay < 0 {
                let effectiveAudioEdge = titleDuration + delay
                #expect(engine.nativeVideoSession?.scrubThumbnailSource(atSeconds: titleDuration - 1) == nil,
                    "Final padding must not already be cached before crossing the original audio EOF")
                await engine.seek(to: effectiveAudioEdge - 1)
                #expect(engine.nativeVideoSession?.scrubThumbnailSource(atSeconds: titleDuration - 1) == nil)
                try await progress(engine, beyond: effectiveAudioEdge + 2)
                #expect(output.copyPixelBuffer(forItemTime: engine.currentAVPlayer!.currentTime(), itemTimeForDisplay: nil) != nil)
                let stats = try #require(engine.nativeVideoSession).diagnosticStats()
                #expect(stats.segmentCacheBytes <= 128 << 20)
                print("NATIVE_MIDDLE_GAP delay=\(delay) edge=\(effectiveAudioEdge) progress=\(engine.currentTime) cache=\(stats.segmentCacheBytes) count=\(stats.segmentCacheCount)")
            }
            let position = delay > 0 ? 190 : titleDuration - 2
            await engine.seek(to: position)
            try await progress(engine, beyond: position + 0.1)
            #expect(output.copyPixelBuffer(forItemTime: engine.currentAVPlayer!.currentTime(), itemTimeForDisplay: nil) != nil)
        }
        print("NATIVE_FULL delay=\(delay) live=\(live) progress=\(engine.currentTime) route=\(engine.videoRoute)")
    }

    /// Cancelling a large finite rebuild at its actual teardown barrier cannot let an old catch-up
    /// loop reopen the replacement source or resurrect an explicitly stopped engine.
    @Test(.enabled(if: (ProcessInfo.processInfo.environment["AETHER_NATIVE_DELAY_FIXTURE"]
                    ?? ProcessInfo.processInfo.environment["TEST_RUNNER_AETHER_NATIVE_DELAY_FIXTURE"]) != nil,
                   "Requires the documented public native hardware-size fixture"), arguments: [false, true])
    func retiringLargeVODRebuildCannotCatchUp(replace: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-cancel-delay-\(UUID()).mp4")
        try IndexedAudioDelayFixture.write(to: url, inputURL: try #require(Self.physicalFixtureURL))
        let engine = try AetherEngine()
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        try await engine.load(url: url, options: LoadOptions(autoplay: true))
        try await progress(engine, beyond: 0.2)
        let gate = ProbeTestGate()
        let original = try #require(engine.nativeVideoSession)
        original.onSessionCacheStatusChanged = { if $0.cleanupReason != nil { gate.wait() } }
        defer { gate.open() }
        engine.setAudioDelay(180)
        try #require(try await waitFor(upTo: .seconds(5)) { gate.entered })
        let retired = engine.liveAudioDelayRejoinTask
        if replace {
            try await engine.load(url: url, options: LoadOptions(autoplay: false, audioDelaySeconds: -0.5))
        } else { engine.stop() }
        let replacement = engine.nativeVideoSession
        gate.open()
        await retired?.value
        #expect(engine.liveAudioDelayRejoinTask == nil)
        #expect(engine.nativeVideoSession === replacement)
        #expect(engine.audioDelaySeconds == (replace ? -0.5 : 180))
        if replace { #expect(engine.nativeHost?.transportIntentIsPlaying == false) }
        else { #expect(engine.state == .idle) }
    }

    /// Seekable custom readers reuse their cursor only after both interrupted reload teardowns have
    /// closed; reset cannot silently remain queued behind the captured large correction.
    @Test(.enabled(if: (ProcessInfo.processInfo.environment["AETHER_NATIVE_DELAY_FIXTURE"]
                    ?? ProcessInfo.processInfo.environment["TEST_RUNNER_AETHER_NATIVE_DELAY_FIXTURE"]) != nil,
                   "Requires the documented public native hardware-size fixture"))
    func seekableCustomPreemptionWaitsForSourceTeardown() async throws {
        let url = try #require(Self.physicalFixtureURL)
        let reader = ProbeRecordingReader(data: try Data(contentsOf: url))
        let engine = try AetherEngine()
        defer { engine.stop() }
        try await engine.load(source: .custom(reader, formatHint: "mp4"), options: LoadOptions(autoplay: false))
        try #require(try await waitFor(upTo: .seconds(5)) { engine.isSessionReady })
        try #require(engine.videoRoute == .loopback && engine.customSourceIsSeekable)
        let original = try #require(engine.nativeVideoSession)
        let barrier = ProbeTestGate()
        original.onSessionCacheStatusChanged = { if $0.cleanupReason != nil { barrier.wait() } }
        defer { barrier.open() }
        engine.setAudioDelay(180)
        try #require(try await waitFor(upTo: .seconds(5)) { barrier.entered })
        let previousOwner = engine.liveAudioDelayRejoinID
        let readsAtBarrier = reader.reads.count
        engine.setAudioDelay(0)
        #expect(engine.liveAudioDelayRejoinID != previousOwner)
        engine.play()
        engine.pause()
        try await Task.sleep(for: .milliseconds(150))
        #expect(reader.reads.count == readsAtBarrier)
        #expect(engine.nativeVideoSession == nil)
        #expect(!engine.needsForegroundVideoRestore)
        barrier.open()
        try #require(try await waitFor(upTo: .seconds(8)) {
            engine.liveAudioDelayRejoinTask == nil && engine.state == .paused
        })
        #expect(engine.videoRoute == .loopback)
        #expect(engine.audioDelaySeconds == 0)
        #expect(engine.nativeVideoSession?.audioDelaySeconds == 0)
        #expect(engine.nativeHost?.transportIntentIsPlaying == false)
        #expect(!engine.sessionPreservingReloadInFlight)
        engine.play()
        try await progress(engine, beyond: 0.2)
    }

    /// Initial and runtime option boundaries accept the same full range and reject non-finite input.
    @Test
    func initialOptionRangeMatchesRuntimePolicy() {
        #expect(LoadOptions(audioDelaySeconds: 181).audioDelaySeconds == 180)
        #expect(LoadOptions(audioDelaySeconds: -181).audioDelaySeconds == -180)
        #expect(LoadOptions(audioDelaySeconds: .nan).audioDelaySeconds == 0)
        #expect(AudioDelayPolicy.requiresRebuild(from: 180, to: 0))
        #expect(!AudioDelayPolicy.requiresRebuild(from: 2, to: -2))
    }
}
