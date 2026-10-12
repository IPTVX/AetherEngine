import Testing
import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// Verifies that rejected spatial routes leave the ordinary audio producer cascade untouched.
@Suite("Object audio fallback")
struct ObjectAudioFallbackTests {
    // Failure modes:
    // - An opt-in must never enable object rendering on a live session.
    // - Plain TrueHD and unsupported sample rates must retain the ordinary bridge.
    // - Before OS 26, even eligible Atmos must retain the ordinary bridge.

    /// Checks that callers omitting the new option retain the previous audio route.
    @Test("Default OFF keeps the ordinary bridge for eligible Atmos")
    func test_spatialProducer_defaultOff_keepsOrdinaryBridge() throws {
        let engine = HLSVideoEngine(
            url: URL(fileURLWithPath: "/nonexistent/object-audio.mkv")
        )

        try expectOrdinaryBridge(engine: engine)
    }

    /// Checks that live playback rejects eligible Atmos before opening a decoder or encoder.
    @Test("Live Atmos keeps the ordinary bridge")
    func test_spatialProducer_liveAtmos_keepsOrdinaryBridge() throws {
        let engine = HLSVideoEngine(
            url: URL(fileURLWithPath: "/nonexistent/object-audio.mkv"),
            objectAudioRendering: .apac(.l714),
            isLiveSession: true
        )

        try expectOrdinaryBridge(engine: engine)
    }

    /// Checks the producer seam rather than only the pure codec eligibility predicate.
    @Test("Plain TrueHD keeps the ordinary bridge")
    func test_spatialProducer_plainTrueHD_keepsOrdinaryBridge() throws {
        let engine = HLSVideoEngine(
            url: URL(fileURLWithPath: "/nonexistent/object-audio.mkv"),
            objectAudioRendering: .apac(.l714)
        )

        try expectOrdinaryBridge(engine: engine, profile: 0)
    }

    /// Checks that an Atmos profile cannot bypass the object decoder's 48 kHz limit.
    @Test("Unsupported Atmos sample rates keep the ordinary bridge", arguments: [Int32(96_000), Int32(192_000)])
    func test_spatialProducer_unsupportedSampleRate_keepsOrdinaryBridge(sampleRate: Int32) throws {
        let engine = HLSVideoEngine(
            url: URL(fileURLWithPath: "/nonexistent/object-audio.mkv"),
            objectAudioRendering: .apac(.l714)
        )

        try expectOrdinaryBridge(engine: engine, sampleRate: sampleRate)
    }

    /// Restricts the legacy route test to runtimes where the APAC availability guard is exercised.
    private static var isLegacyRuntime: Bool {
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) {
            return false
        }
        return true
    }

    /// Exercises the actual availability fallback on an OS 16–25 runtime, otherwise reports a skip.
    @Test(
        "Before OS 26 eligible Atmos keeps the ordinary bridge",
        .enabled(if: ObjectAudioFallbackTests.isLegacyRuntime, "Requires a runtime below OS 26")
    )
    func test_spatialProducer_legacyOS_keepsOrdinaryBridge() throws {
        let engine = HLSVideoEngine(
            url: URL(fileURLWithPath: "/nonexistent/object-audio.mkv"),
            objectAudioRendering: .apac(.l714)
        )

        try expectOrdinaryBridge(engine: engine)
    }

    /// Builds an owned FFmpeg stream without opening media and verifies no spatial state is installed.
    /// The caller can continue its ordinary audio bridge cascade after the nil producer result.
    private func expectOrdinaryBridge(
        engine: HLSVideoEngine,
        profile: Int32 = 30,
        sampleRate: Int32 = 48_000
    ) throws {
        let context = try #require(avformat_alloc_context())
        defer { avformat_free_context(context) }
        let stream = try #require(avformat_new_stream(context, nil))
        stream.pointee.time_base = AVRational(num: 1, den: 1000)
        stream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_TRUEHD
        stream.pointee.codecpar.pointee.profile = profile
        stream.pointee.codecpar.pointee.sample_rate = sampleRate
        var codecs: String? = "ordinary-bridge"

        let producer = engine.buildSpatialAudioProducerIfEligible(
            audioStream: stream,
            sourceAudioStreamIndex: 0,
            sourceCodecLabel: "TrueHD",
            audioHLSCodecs: &codecs,
            audioLanguage: "eng"
        )

        #expect(producer == nil)
        #expect(engine.audioBridge == nil)
        #expect(engine.savedAudioConfig == nil)
        #expect(codecs == "ordinary-bridge")
    }
}
