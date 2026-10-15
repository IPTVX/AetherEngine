import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import os
import Testing
@testable import AetherEngine

/// The FEL path's start: the clock waits at rate 0 until composed frames are in the layer, then
/// starts a fixed lead from now (`AudioOutput.videoPrerollSatisfied`, `prerollStartLead`,
/// `SampleBufferRenderer.felPrerollSatisfied(clock:)`). On an Apple TV 4K a clock started the moment
/// the first packet arrived dropped 3 to 5 frames at every start and seek; with both, none.
@Suite("Video preroll before the clock starts")
struct VideoPrerollTests {

    private static func makePixelBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        return pb!
    }

    private static func time(_ index: Int) -> CMTime { CMTime(value: Int64(index) * 1000, timescale: 24000) }

    // MARK: - Renderer gate

    @Test("Off the FEL path the renderer has no opinion, so the clock starts at once")
    @MainActor
    func noGateOffTheFELPath() {
        let renderer = SampleBufferRenderer()
        #expect(renderer.felPrerollSatisfied(clock: 0) == nil)
    }

    @Test("The gate opens once the contiguous frames reach the preroll past the clock")
    @MainActor
    func gateCountsContiguousFrames() {
        let renderer = SampleBufferRenderer()
        renderer.setFELLookahead(enabled: true, frameRate: 24)
        renderer.setArrivalOrderHandover(frameRate: 24)
        let pixels = Self.makePixelBuffer()
        #expect(renderer.felPrerollSatisfied(clock: 0) == false, "nothing handed over yet")
        // A frame past a gap does not count: 0, 1, 2 and then 6 leave the frontier at frame 2.
        for i in [0, 1, 2, 6] { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i)) }
        #expect(renderer.felPrerollSatisfied(clock: 0) == false)
        // 0 to 3 is four frames, 0.1667 s: just short of the preroll.
        renderer.enqueue(pixelBuffer: pixels, pts: Self.time(3))
        #expect(renderer.felPrerollSatisfied(clock: 0) == false)
        renderer.enqueue(pixelBuffer: pixels, pts: Self.time(4))
        #expect(renderer.felPrerollSatisfied(clock: 0) == true)
        // The same frames are not enough for a clock further on.
        #expect(renderer.felPrerollSatisfied(clock: Self.time(4).seconds) == false)
    }

    @Test("After a seek the gate counts from the seek target, not from the frames before it")
    @MainActor
    func gateRestartsAtTheSeekTarget() {
        let renderer = SampleBufferRenderer()
        renderer.setFELLookahead(enabled: true, frameRate: 24)
        renderer.setArrivalOrderHandover(frameRate: 24)
        let pixels = Self.makePixelBuffer()
        for i in 0..<20 { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i)) }
        renderer.flush(removingDisplayedImage: false)
        renderer.setSkipThreshold(Self.time(100))
        let target = Self.time(100).seconds
        #expect(renderer.felPrerollSatisfied(clock: target) == false)
        for i in 100..<105 { renderer.enqueue(pixelBuffer: pixels, pts: Self.time(i)) }
        #expect(renderer.felPrerollSatisfied(clock: target) == true)
    }

    // MARK: - Clock

    /// A gate the test opens by hand.
    private final class Gate: Sendable {
        private let open = OSAllocatedUnfairLock(initialState: false)
        func set(_ value: Bool) { open.withLock { $0 = value } }
        var isOpen: Bool { open.withLock { $0 } }
    }

    @Test("Without a gate seekClock starts the clock at once", .timeLimit(.minutes(1)))
    func startsAtOnceWithoutAGate() {
        let output = AudioOutput()
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        #expect(output.synchronizer.rate == 1)
    }

    @Test("A closed gate holds the clock at rate 0 and the start follows when it opens",
          .timeLimit(.minutes(1)))
    func holdsUntilTheGateOpens() async throws {
        let output = AudioOutput()
        let gate = Gate()
        output.videoPrerollSatisfied = { _ in gate.isOpen }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        #expect(output.synchronizer.rate == 0)
        #expect(abs(output.synchronizer.currentTime().seconds - 5) < 0.001)
        let opened = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        gate.set(true)
        try await waitFor { output.synchronizer.rate == 1 }
        // The start was scheduled `prerollStartLead` after the gate opened, so however late this
        // runs, the clock has not run longer than the time since then minus the lead.
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let ran = max(0, now - opened - AudioOutput.prerollStartLead)
        #expect(output.synchronizer.currentTime().seconds <= 5 + ran + 0.02)
    }

    @Test("A rate set while the preroll waits is the rate it starts at", .timeLimit(.minutes(1)))
    func setRateDuringPrerollIsTheStartRate() async throws {
        let output = AudioOutput()
        let gate = Gate()
        output.videoPrerollSatisfied = { _ in gate.isOpen }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        output.setRate(1.5)
        #expect(output.synchronizer.rate == 0, "the rate does not start the clock early")
        gate.set(true)
        try await waitFor { output.synchronizer.rate == 1.5 }
    }

    @Test("A pause cancels the pending start", .timeLimit(.minutes(1)))
    func pauseCancelsThePreroll() async throws {
        let output = AudioOutput()
        let gate = Gate()
        output.videoPrerollSatisfied = { _ in gate.isOpen }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        output.pause()
        gate.set(true)
        let started = try await waitFor(upTo: .milliseconds(300)) { output.synchronizer.rate != 0 }
        #expect(!started)
    }

    @Test("A gate that never opens starts the clock after the timeout", .timeLimit(.minutes(1)))
    func timesOut() async throws {
        let output = AudioOutput()
        output.videoPrerollSatisfied = { _ in false }
        output.seekClock(to: CMTime(seconds: 5, preferredTimescale: 90000), rate: 1)
        #expect(output.synchronizer.rate == 0)
        try await waitFor { output.synchronizer.rate == 1 }
    }
}
