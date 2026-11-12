#if os(iOS) || os(tvOS) || os(visionOS)
import AVFoundation
import Foundation
import MediaPlayer
import Testing
@testable import AetherEngine

/// Exercises the actual AVPlayer audio route and session through a sequence of loads.
@Suite("IPTVX native audio Now Playing ownership")
@MainActor
struct AudioNowPlayingOwnershipTests {
    /// Checks that native audio playback can leave the system card to the app before load and on host reuse.
    @Test func test_audioLoad_sessionOwnershipChanges_reusesPlayerWithoutAnEnginePublisher() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData?.pointee)
        for index in 0..<Int(buffer.frameLength) { samples[index] = 0 }
        do {
            let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
            try file.write(from: buffer)
        }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let options = LoadOptions(audioOnly: true, autoplay: false)

        engine.ownsAudioNowPlayingSession = false
        try await engine.load(url: fileURL, options: options)
        #expect(engine.audioAVPlayerActive)
        let player = try #require(engine.audioAVPlayerHost?.avPlayer)
        #expect(engine.audioNowPlayingSession == nil)
        #expect(engine.nowPlayingController == nil)

        engine.ownsAudioNowPlayingSession = true
        try await engine.load(url: fileURL, options: options)
        let session = try #require(engine.audioNowPlayingSession)
        #expect(session.automaticallyPublishesNowPlayingInfo)
        #expect(session.players.first === player)
        #expect(engine.nowPlayingController == nil)

        engine.ownsAudioNowPlayingSession = false
        try await engine.load(url: fileURL, options: options)
        #expect(engine.audioAVPlayerHost?.avPlayer === player)
        #expect(engine.audioNowPlayingSession == nil)
        #expect(!session.automaticallyPublishesNowPlayingInfo)
        #expect(session.players.isEmpty)
        #expect(engine.nowPlayingController == nil)
    }
}
#endif
