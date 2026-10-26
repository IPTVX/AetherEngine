import AVFoundation
import CoreMedia
import Testing
@testable import AetherEngine

/// Compressed renderer output and its separately decoded PCM tap share startup admission.
struct SoftwareAudioTapPrerollTests {
    // Failure modes:
    // - The renderer crosses the cutoff before its producer returns older PCM tap samples.
    // - A seek makes a captured startup cutoff irrelevant to the new timeline.

    /// Builds one deterministic PCM frame whose timestamp controls startup admission.
    private func sample(at seconds: Double) throws -> CMSampleBuffer {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: true
        ))
        var block: CMBlockBuffer?
        try #require(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: 4,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: 4,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        ) == noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000),
            decodeTimeStamp: .invalid
        )
        var buffer: CMSampleBuffer?
        try #require(CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: try #require(block),
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format.formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &buffer
        ) == noErr)
        return try #require(buffer)
    }

    /// Converts accepted samples into timestamps so assertions describe the observable tap output.
    private func times(_ buffers: [CMSampleBuffer]) -> [Double] {
        buffers.map { CMSampleBufferGetPresentationTimeStamp($0).seconds }
    }

    @Test("PCM tap keeps the packet's cutoff after renderer output crosses it")
    func transformedTapDropsEarlierPCM() throws {
        // Arrange — one producer emits renderer and PCM buffers with different timestamp spans.
        let rendererBuffers = [try sample(at: 10)]
        let pcmBuffers = [try sample(at: 9), try sample(at: 10), try sample(at: 11)]
        let cutoff = 10.0
        let generation: UInt64 = 3

        // Act — renderer admission precedes the independently transformed tap output.
        let rendererOutput = SoftwarePlaybackHost.startupAudioTapBuffers(
            rendererBuffers,
            discardBeforeSeconds: cutoff,
            startupGeneration: generation,
            currentGeneration: generation
        )
        let tapOutput = SoftwarePlaybackHost.startupAudioTapBuffers(
            pcmBuffers,
            discardBeforeSeconds: cutoff,
            startupGeneration: generation,
            currentGeneration: generation
        )

        // Assert — the older PCM sample cannot enter transcription after video-aligned playback starts.
        #expect(times(rendererOutput) == [10])
        #expect(times(tapOutput) == [10, 11])
    }

    @Test("a seek retires the startup cutoff instead of trimming the new tap timeline")
    func newGenerationKeepsItsSamples() throws {
        // Arrange — a post-seek PCM sample precedes the outgoing startup's cutoff.
        let pcmBuffers = [try sample(at: 2)]

        // Act — the snapshot belongs to an earlier generation.
        let output = SoftwarePlaybackHost.startupAudioTapBuffers(
            pcmBuffers,
            discardBeforeSeconds: 10,
            startupGeneration: 3,
            currentGeneration: 4
        )

        // Assert — startup preroll from the old generation does not govern this timeline.
        #expect(times(output) == [2])
    }
}
