import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Covers a reader that observes a source seam while older compressed media is still queued.
@Suite("Software audio-delay epoch admission")
struct SoftwareAudioDelayEpochTests {
    /// The exact decoder-reset policy follows consumed records, never source read-ahead state.
    @Test
    func sourceSeamDoesNotResetOldQueuedPackets() throws {
        let input: [(Int32, Int64)] = [(0, 0), (1, 0), (0, 4), (1, 4), (0, 100), (1, 100)]
        var index = 0
        let source = SoftwareAudioDelayPacketSource(
            video: 0, audio: 1, foldsTimeline: true,
            timeBase: { _ in AVRational(num: 1, den: 1) },
            readSource: {
                if index == input.count { return nil }
                let item = input[index]; index += 1
                return try SoftwareStoredPacket(
                    pts: item.1, dts: item.1, duration: 5, position: Int64(index),
                    streamIndex: item.0, flags: AV_PKT_FLAG_KEY,
                    timeBaseNumerator: 1, timeBaseDenominator: 1,
                    bytes: Data([1]), sideData: []).makeAVPacket()
            }, isCurrent: { true }, recordingTap: { _ in }, prepared: { _, _ in })
        let alignment = try CompressedAudioDelayAlignment(
            delaySeconds: 3, byteBudget: 1 << 20,
            readSource: { try source.read() }, isCurrent: { true })
        defer { try? alignment.close() }
        var boundary = SoftwareAudioDelayEpochBoundary()
        var output: [UInt64] = []
        var resetPositions: [Int] = []
        var observedFutureSourceBeforeOldDelivery = false
        while let packet = try alignment.read() {
            if source.epoch > packet.epoch { observedFutureSourceBeforeOldDelivery = true }
            if boundary.consumes(packet.epoch) { resetPositions.append(output.count) }
            output.append(packet.epoch)
        }
        #expect(observedFutureSourceBeforeOldDelivery)
        #expect(output == [0, 0, 0, 0, 1, 1])
        #expect(resetPositions == [4])
    }

    /// DVR alignment stores every original decode field instead of reconstructing DTS from PTS.
    @Test
    func dvrRingRetainsLosslessEnvelope() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("aligned-ring-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let ring = try PacketRingBuffer(windowSeconds: 240, scratch: scratch, byteBudget: 1 << 20)
        defer { ring.close() }
        let record = SoftwareStoredPacket(
            pts: 180, dts: 178, duration: 2, position: 123, streamIndex: 3, flags: AV_PKT_FLAG_KEY,
            timeBaseNumerator: 1, timeBaseDenominator: 25, bytes: Data([1, 2, 3]),
            sideData: [.init(type: 0, bytes: Data([4, 5]))])
        try ring.append(packet: record, pts: 7.2, isKeyframe: true, isVideo: true, epoch: 42)
        let packet = try #require(ring.packet(atSeq: ring.seqBounds.first))
        #expect(packet.bytes == record.bytes)
        #expect(packet.storedPacket == record)
        #expect(try ring.alignmentPacket(atSeq: ring.seqBounds.first)?.alignmentEpoch == 42)
        #expect(ring.diskBytes >= record.bytes.count)
    }
    /// Headers and protected consumed prefixes are part of the aligned cache's single partition.
    @Test
    func alignedCacheCannotBorrowItsOtherQueuePartition() throws {
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 32, retainConsumed: true,
                                              maximumResidentBytes: 32)
        defer { try? fifo.close() }
        try fifo.append(Data(repeating: 1, count: 8))
        _ = try fifo.pop()
        #expect(fifo.snapshot.diskByteCount == 16)
        #expect(throws: SoftwarePacketDiskFIFO.Failure.residentCapacityExceeded(requiredBytes: 33, maximumBytes: 32)) {
            try fifo.append(Data(repeating: 2, count: 9))
        }
        #expect(fifo.snapshot.diskByteCount == 16)
    }

    /// A full cache parks with one pending compressed record and resumes after consumer eviction.
    @Test(.offCooperativePool, .timeLimit(.minutes(1)))
    func alignedCacheSaturationContinuesWithoutExceedingItsPartition() throws {
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 128, retainConsumed: true,
                                              maximumResidentBytes: 256)
        let produced = ProbeTestBox(0)
        let source = SoftwarePacketReadAhead(
            video: .init(index: 0, numerator: 1, denominator: 1), audio: nil,
            byteBudget: 256, forwardSeconds: 1_000, maximumResidentBytes: 256,
            initialSourceClock: 0, fifo: fifo) { _ in
                let index = produced.value
                if index == 32 { return nil }
                produced.update { $0 += 1 }
                return SoftwareStoredPacket(pts: Int64(index), dts: Int64(index), duration: 1,
                    position: Int64(index), streamIndex: 0, flags: 1,
                    timeBaseNumerator: 1, timeBaseDenominator: 1,
                    bytes: Data(repeating: 7, count: 32), sideData: [])
            }
        source.start()
        defer { source.close() }
        while !source.producerParkedForTesting { Thread.sleep(forTimeInterval: 0.005) }
        var timestamps: [Int64] = []
        while let packet = try source.read() {
            timestamps.append(packet.pts)
            #expect(fifo.snapshot.diskByteCount <= 256)
        }
        #expect(timestamps == Array(0..<32).map(Int64.init))
    }

    /// A malformed resident record fails immediately instead of looking like an empty Live edge.
    @Test
    func malformedResidentEnvelopeIsAnExplicitFailure() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("corrupt-aligned-ring-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let ring = try PacketRingBuffer(windowSeconds: 240, scratch: scratch, byteBudget: 1 << 20)
        defer { ring.close() }
        try Data([0, 1]).withUnsafeBytes {
            try ring.append(pts: 0, isKeyframe: true, isVideo: true, bytes: $0, storesEnvelope: true)
        }
        #expect(throws: PacketRingBuffer.Failure.corruptEnvelope) {
            _ = try ring.storedPacket(atSeq: ring.seqBounds.first)
        }
    }

}
