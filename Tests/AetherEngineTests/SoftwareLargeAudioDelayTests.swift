import Foundation
import Testing
@testable import AetherEngine

/// Exercises actual renderer admission and video progress through the software playback host.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct SoftwareLargeAudioDelayTests {
    // Failure modes:
    // - Large offsets appear in getters but delivered samples remain on the old timeline.
    // - Finite video is skipped to obtain a missing leading audio interval.
    // - Empty trailing audio permanently parks the master clock.

    /// Uses unique sources so concurrent suites cannot overwrite or tear down each other's files.
    private func withEngine(delay: Double, live: Bool, dvrWindow: Double? = nil,
                            body: (AetherEngine, ProbeTestBox<[(Double, Double)]>) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("software-aligned-\(UUID()).ts")
        try await BlockingWork.detached(priority: .userInitiated) {
            try LongAudioDelayTransportStreamFixture.write(to: url)
        }.value
        let engine = try AetherEngine()
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        try await engine.load(url: url, options: LoadOptions(
            isLive: live, dvrWindowSeconds: dvrWindow, autoplay: false,
            audioDelaySeconds: delay, preferredDecodePath: .software))
        try #require(engine.videoRoute == .software)
        let delivery = ProbeTestBox<[(Double, Double)]>([])
        engine.softwareHost?.observeDeliveredAudioForTesting { source, delivered in
            delivery.update { if $0.count < 32 { $0.append((source, delivered)) } }
        }
        try await body(engine, delivery)
    }

    /// Both signs reach actual audio buffers while the displayed video clock continues advancing.
    @Test(arguments: [-180.0, 180.0], [false, true])
    func deliveredTimingAndVideoProgress(delay: Double, live: Bool) async throws {
        try await withEngine(delay: delay, live: live) { engine, delivery in
            if !live && delay > 0 { await engine.seek(to: 190) }
            let initial = engine.currentTime
            engine.play()
            try await waitFor { !delivery.value.isEmpty || engine.errorInfo != nil }
            try #require(engine.errorInfo == nil)
            let observed = try #require(delivery.value.first)
            #expect(abs(observed.1 - observed.0 - delay) < 0.001)
            try await waitFor { engine.currentTime > initial + 0.25 || engine.errorInfo != nil }
            #expect(engine.errorInfo == nil)
            #expect(engine.softwareHost?.videoRendererForTesting.takeCadence().handedOver ?? 0 > 0)
            if live { #expect(engine.liveWindow?.windowSeconds == nil) }
        }
    }

    /// Large offsets can leave a whole short title silent; video must still play and reach EOF.
    @Test(arguments: [-180.0, 180.0])
    func wholeTitleWithoutOverlappingAudioDoesNotHang(delay: Double) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("software-gap-\(UUID()).ts")
        try LongGOPTransportStreamFixture.data().write(to: url)
        let engine = try AetherEngine()
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        try await engine.load(url: url, options: LoadOptions(
            autoplay: false, audioDelaySeconds: delay, preferredDecodePath: .software))
        await engine.seek(to: 30)
        let framesBefore = engine.softwareHost?.videoRendererForTesting.takeCadence().handedOver ?? 0
        engine.play()
        try await waitFor { engine.currentTime > 30.25 || engine.errorInfo != nil }
        #expect(engine.errorInfo == nil)
        try await waitFor { engine.state == .ended || engine.errorInfo != nil }
        #expect(engine.state == .ended)
        #expect(engine.currentTime > 30.25)
        #expect(engine.softwareHost?.videoRendererForTesting.takeCadence().handedOver ?? 0 > framesBefore)
    }

    /// Seeking into the negative-offset silent tail must not wait for nonexistent future audio.
    @Test
    func negativeOffsetSilentTailReachesEOF() async throws {
        try await withEngine(delay: -180, live: false) { engine, _ in
            await engine.seek(to: 254)
            let framesBefore = engine.softwareHost?.videoRendererForTesting.takeCadence().handedOver ?? 0
            engine.play()
            try await waitFor { engine.currentTime > 254.25 || engine.errorInfo != nil }
            #expect(engine.errorInfo == nil)
            try await waitFor { engine.state == .ended || engine.errorInfo != nil }
            #expect(engine.state == .ended)
            #expect(engine.currentTime > 254.25)
            #expect(engine.softwareHost?.videoRendererForTesting.takeCadence().handedOver ?? 0 > framesBefore)
        }
    }

    /// The public DVR edge describes video with available shifted audio, then a seek keeps delivery.
    @Test(arguments: [-180.0, 180.0])
    func dvrAvailabilityAndSeekPreserveAlignment(delay: Double) async throws {
        try await withEngine(delay: delay, live: true, dvrWindow: 240) { engine, delivery in
            engine.play()
            try await waitFor { !delivery.value.isEmpty || engine.errorInfo != nil }
            try #require(engine.errorInfo == nil)
            try await waitFor { engine.seekableLiveRange != nil }
            let range = try #require(engine.seekableLiveRange)
            #expect(range.upperBound - range.lowerBound <= 240.1)
            if delay < 0 { #expect(range.upperBound < 90) }
            let target = max(range.lowerBound, range.upperBound - 4)
            let host = try #require(engine.softwareHost)
            engine.pause()
            let framesBefore = host.videoRendererForTesting.takeCadence().handedOver
            await engine.seek(to: target)
            #expect(abs(engine.currentTime - target) < 0.1)
            engine.play()
            let deliveredNearTarget = try await waitFor(upTo: .seconds(3)) {
                engine.currentTime > target + 0.25
                    && host.videoRendererForTesting.takeCadence().handedOver > framesBefore
                    || engine.errorInfo != nil
            }
            #expect(deliveredNearTarget)
            #expect(engine.currentTime >= target - 0.1 && engine.currentTime < target + 3.5)
            #expect(engine.errorInfo == nil)
            #expect(delivery.value.allSatisfy { abs($0.1 - $0.0 - delay) < 0.001 })
        }
    }

    /// A source ending under Live semantics retires shifted tails instead of playing unmatched media.
    @Test(arguments: [-3.0, 3.0])
    func liveSourceEOFStopsAtMatchedInterval(delay: Double) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("software-live-eof-\(UUID()).ts")
        try LongGOPTransportStreamFixture.data().write(to: url)
        let engine = try AetherEngine()
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        try await engine.load(url: url, options: LoadOptions(isLive: true, dvrWindowSeconds: 60,
            autoplay: false, audioDelaySeconds: delay, preferredDecodePath: .software))
        let host = try #require(engine.softwareHost)
        let latestAudioPresentation = ProbeTestBox<Double?>(nil)
        host.observeDeliveredAudioForTesting { _, presented in
            latestAudioPresentation.update { $0 = max($0 ?? presented, presented) }
        }
        engine.play()
        try await waitFor {
            if engine.errorInfo != nil { return true }
            let source = host.liveSourceEndForTesting
            guard source.hasEnded, engine.currentTime > 0.05,
                  let sourceEdge = source.edge, let publishedEdge = engine.seekableLiveRange?.upperBound else { return false }
            return abs(sourceEdge - publishedEdge) < 0.01
        }
        try #require(engine.errorInfo == nil)
        let range = try #require(engine.seekableLiveRange)
        engine.pause()
        let framesBefore = host.videoRendererForTesting.takeCadence().handedOver
        await engine.seek(to: max(range.lowerBound, range.upperBound - 2))
        engine.play()
        try await waitFor {
            host.didReachEnd || engine.currentTime > range.upperBound + 0.25 || engine.errorInfo != nil
        }
        try await waitFor {
            host.rate == 0 || engine.currentTime > range.upperBound + 0.25 || engine.errorInfo != nil
        }
        #expect(engine.errorInfo == nil)
        #expect(host.didReachEnd)
        #expect(host.rate == 0)
        #expect(engine.currentTime <= range.upperBound + 0.25)
        #expect(host.videoRendererForTesting.takeCadence().handedOver > framesBefore)
        if let presented = latestAudioPresentation.value {
            #expect(presented <= host.sourceSeconds(forSession: range.upperBound) + 0.1)
        } else {
            Issue.record("Live EOF regression did not admit any audio buffer")
        }
    }

    /// Clearing a large offset reconstructs its latched queues while preserving an explicit pause.
    @Test(arguments: [false, true])
    func largeToZeroPreservesPauseAndCanStop(live: Bool) async throws {
        try await withEngine(delay: -180, live: live) { engine, delivery in
            engine.play()
            try await waitFor { !delivery.value.isEmpty || engine.errorInfo != nil }
            try #require(engine.errorInfo == nil)
            engine.pause()
            let previous = try #require(engine.softwareHost)
            engine.setAudioDelay(0)
            try await waitFor { engine.softwareHost != nil && engine.softwareHost !== previous && engine.state == .paused }
            #expect(engine.audioDelaySeconds == 0)
            let position = engine.currentTime
            engine.play()
            try await waitFor { engine.currentTime > position + 0.25 || engine.errorInfo != nil }
            #expect(engine.errorInfo == nil)
            engine.setAudioDelay(-180)
            engine.stop()
            let correction = engine.liveAudioDelayRejoinTask
            await correction?.value
            #expect(engine.softwareHost == nil)
            #expect(engine.state == .idle)
        }
    }
}
