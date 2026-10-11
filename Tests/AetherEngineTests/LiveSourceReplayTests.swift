import Foundation
import Testing
import AetherLibavutil
import AetherLibavcodec
@testable import AetherEngine

@Suite("Live source replay", .serialized, .timeLimit(.minutes(1)))
struct LiveSourceReplayTests {
    private final class Reader: IOReader, @unchecked Sendable {
        private let bytes: Data
        private let failAtEnd: Bool
        private let lock = NSLock()
        private var position = 0
        init(_ bytes: Data, failAtEnd: Bool = false) {
            self.bytes = bytes
            self.failAtEnd = failAtEnd
        }
        var consumedBytes: Int { lock.withLock { position } }
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            guard let buffer, size > 0 else { return -1 }
            return lock.withLock {
                let count = min(Int(size), bytes.count - position)
                guard count > 0 else { return failAtEnd ? -1 : 0 }
                bytes.withUnsafeBytes { _ = memcpy(buffer, $0.baseAddress! + position, count) }
                position += count
                return Int32(count)
            }
        }
        func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
        func close() {}
        var discImageProbeEnabled: Bool { false }
    }

    private final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var exit: HLSSegmentProducer.PumpExitReason?
        private var rebases = 0
        func finish(_ reason: HLSSegmentProducer.PumpExitReason) { lock.withLock { exit = reason } }
        func rebase() { lock.withLock { rebases += 1 } }
        var reason: HLSSegmentProducer.PumpExitReason? { lock.withLock { exit } }
        var rebaseCount: Int { lock.withLock { rebases } }
    }

    /// Split on TS packets carrying a video access-unit delimiter, retaining the original
    /// compressed frames and source timestamps. Changing an AUD leaves the picture intact.
    private func fixture(data: Data = TinyTransportStreamFixture.data,
                         divergenceFrame: Int = 5,
                         divergenceFrames: Int = 1,
                         headFrames: Int = 8,
                         replayStartFrame: Int = 0) throws -> (head: Data, tail: Data,
                                                              replay: Data, diverged: Data) {
        let aud = Data([0, 0, 0, 1, 9, 0xF0])
        var offsets: [Int] = []
        var position = 0
        while let range = data.range(of: aud, in: position..<data.count) {
            offsets.append(range.lowerBound)
            position = range.upperBound
        }
        #expect(offsets.count == 16)
        let seam = try #require(offsets.dropFirst(headFrames).first) / 188 * 188
        let head = Data(data[..<seam])
        let replayStart = replayStartFrame == 0 ? 0 : offsets[replayStartFrame] / 188 * 188
        let replay = Data(head[replayStart...])
        var diverged = replay
        for offset in offsets.dropFirst(divergenceFrame).prefix(divergenceFrames) {
            let changedAUD = offset + 5 - replayStart
            if changedAUD < diverged.count { diverged[changedAUD] = 0xD0 }
        }
        return (head, Data(data[seam...]), replay, diverged)
    }

    @discardableResult
    private func run(_ bytes: Data, expected: String, expectedRebases: Int,
                     failAtEnd: Bool = false, mustLeaveUnreadBytes: Bool = false,
                     retainedCache: SegmentCache? = nil,
                     predecessor: HLSSegmentProducer? = nil) async throws -> HLSSegmentProducer {
        let demuxer = Demuxer()
        let reader = Reader(bytes, failAtEnd: failAtEnd)
        try demuxer.open(reader: reader, formatHint: "mpegts")
        let index = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: index))
        var audio: HLSSegmentProducer.AudioConfig?
        if let stream = demuxer.stream(at: demuxer.audioStreamIndex) {
            audio = .init(codecpar: UnsafePointer(stream.pointee.codecpar),
                          timeBase: stream.pointee.time_base,
                          sourceStreamIndex: demuxer.audioStreamIndex,
                          inputTimeBase: stream.pointee.time_base,
                          sourceTimeBase: stream.pointee.time_base,
                          bridge: nil, stripAacAdts: true)
        }
        let cache = retainedCache ?? SegmentCache(forwardWindow: 32, backwardWindow: 32)
        let baseIndex = predecessor == nil ? 0 : cache.count
        let producer = try HLSSegmentProducer(
            demuxer: demuxer, videoStreamIndex: index,
            video: .init(codecpar: UnsafePointer(stream.pointee.codecpar),
                         timeBase: stream.pointee.time_base, codecTagOverride: "avc1"),
            audio: audio, cache: cache, baseIndex: baseIndex, targetSegmentDurationSeconds: 1,
            videoFallbackDurationPts: 45_000, desiredFirstVideoTfdtPts: Int64(baseIndex) * 90_000,
            segmentBoundaries: [], isLive: true, bufferAheadSegments: 32)
        if let predecessor { producer.continueLiveReplayHistory(from: predecessor) }
        let result = Result()
        defer {
            producer.stop()
            // Cancellation may leave the pump unwinding; its demuxer/cache must stay alive.
            if result.reason != nil, retainedCache == nil { cache.close() }
        }
        producer.onPumpFinished = { result.finish($0) }
        producer.onLiveTimelineRebase = { _, _ in result.rebase() }
        producer.onLiveSegmentFinalized = { _, _, _, _ in }
        producer.start()
        try await waitFor { result.reason != nil }
        #expect(result.reason?.description == expected)
        #expect(result.rebaseCount == expectedRebases,
                "confirmed old media must never enter the discontinuity/mux path")
        #expect(cache.count > 0, "the already-produced good media remains available")
        if mustLeaveUnreadBytes {
            #expect(reader.consumedBytes < bytes.count, "the packet bound fires before source EOF")
        }
        return producer
    }

    private final class AdmissionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var held = false
        private var sawHold = false
        private var reads = 0
        private var ended = false
        private var stopped = false
        func noteRead() { lock.withLock { reads += 1; if reads == 1 { held = true } } }
        func mayRead() -> Bool { lock.withLock { if held { sawHold = true }; return !held } }
        func release() { lock.withLock { held = false } }
        func stop() { lock.withLock { stopped = true; held = false } }
        func finish() { lock.withLock { ended = true } }
        var blocked: Bool { lock.withLock { sawHold } }
        var done: Bool { lock.withLock { ended } }
        var shouldStop: Bool { lock.withLock { stopped } }
    }

    @Test("software acquisition cannot evict a cursor while its recovery transition is held")
    func readerHonoursDVRRecoveryHold() async throws {
        let demuxer = Demuxer()
        try demuxer.open(reader: Reader(TinyTransportStreamFixture.data), formatHint: "mpegts")
        let video = demuxer.videoStreamIndex
        let tb = try #require(demuxer.stream(at: video)).pointee.time_base
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ring = try PacketRingBuffer(windowSeconds: 2, scratch: directory)
        let condition = NSCondition()
        let gate = AdmissionGate()
        defer { gate.stop(); condition.withLock { condition.broadcast() } }
        Thread.detachNewThread {
            defer { demuxer.close(); gate.finish() }
            SoftwarePlaybackHost.runLiveReaderLoop(demuxer: demuxer,
                videoStreamIndex: video, audioStreamIndex: -1, condition: condition, ring: ring,
                videoTimeBaseSeconds: Double(tb.num) / Double(tb.den), audioTimeBaseSeconds: 0,
                noteEdge: { _ in gate.noteRead() }, readerMayAdvance: { gate.mayRead() },
                stopRequested: { gate.shouldStop }, onError: { _ in gate.stop() },
                onSourceEnded: {})
        }
        try await waitFor { gate.blocked || gate.done }
        #expect(gate.blocked)
        #expect(ring.seqBounds.first == 0)
        #expect(ring.seqBounds.end == 1)
        gate.release(); condition.withLock { condition.broadcast() }
        try await waitFor { gate.done }
        #expect(ring.seqBounds.end > 1)
        ring.close()
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("software admission removes real H264/AAC replay before the DVR timeline")
    func softwarePacketAdmission() throws {
        let clip = try fixture(data: Self.audioVideoFixture(), headFrames: 12, replayStartFrame: 2)
        func signatures(_ bytes: Data) throws -> [LivePacketReplayGuard.Signature] {
            let demuxer = Demuxer()
            try demuxer.open(reader: Reader(bytes), formatHint: "mpegts", isLive: true)
            defer { demuxer.close() }
            let video = demuxer.videoStreamIndex
            let audio = demuxer.audioStreamIndex
            let vt = try #require(demuxer.stream(at: video)).pointee.time_base
            let at = try #require(demuxer.stream(at: audio)).pointee.time_base
            let filter = LiveReplayPacketReader(videoIndex: video, audioIndex: audio,
                videoTimeBase: Double(vt.num) / Double(vt.den), audioTimeBase: Double(at.num) / Double(at.den))
            var result: [LivePacketReplayGuard.Signature] = []
            while let packet = try filter.read(from: { try demuxer.readPacket() }) {
                defer { var owned: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&owned) }
                guard packet.pointee.stream_index == video || packet.pointee.stream_index == audio,
                      let data = packet.pointee.data, packet.pointee.size > 0 else { continue }
                result.append(.init(stream: packet.pointee.stream_index == video ? .video : .audio,
                    dts: packet.pointee.dts, pts: packet.pointee.pts,
                    payload: UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size))))
            }
            return result
        }
        let baseline = try signatures(clip.head + clip.tail)
        let recovered = try signatures(clip.head + clip.replay + clip.tail)
        // TS/PES interleaving can change at the seam; each decoder must still receive
        // exactly its original compressed packets, in original per-track order.
        for track in [LivePacketReplayGuard.Stream.video, .audio] {
            #expect(recovered.filter { $0.stream == track } == baseline.filter { $0.stream == track })
        }
    }

    @Test("fresh producers keep cached replay history through repeated source recoveries")
    func freshProducerDoesNotAppendCachedPicturesAgain() async throws {
        let clip = try fixture()
        let cache = SegmentCache(forwardWindow: 32, backwardWindow: 32)
        defer { cache.close() }
        let first = try await run(clip.head + clip.diverged, expected: "sourceReplay", expectedRebases: 0,
                                  retainedCache: cache)
        let retainedSegments = cache.count
        let second = try await run(clip.head + clip.tail, expected: "eof", expectedRebases: 0,
                                   retainedCache: cache, predecessor: first)
        let control = try await run(clip.head + clip.tail, expected: "eof", expectedRebases: 0)
        #expect(first.packetsWrittenCount + second.packetsWrittenCount == control.packetsWrittenCount,
                "every picture is admitted once, including intact tail packets held before source loss")
        #expect(cache.count > retainedSegments)
        let beforeThird = cache.count
        let third = try await run(clip.head + clip.tail, expected: "sourceReplay", expectedRebases: 0,
                                  retainedCache: cache, predecessor: second)
        #expect(third.packetsWrittenCount == 0,
                "a third fresh connection repeating the entire cached broadcast produces nothing")
        #expect(cache.count == beforeThird, "previous DVR media is retained through repeated source loss")
    }

    @Test("exact overlap continues without rebasing the output")
    func exactOverlap() async throws {
        let clip = try fixture()
        try await run(clip.head + clip.head + clip.tail, expected: "eof", expectedRebases: 0)
    }

    @Test("a damaged packet inside verified overlap does not replay or restart the source")
    func divergentOverlapDoesNotReplayItsPrefix() async throws {
        let clip = try fixture()
        let result = try await run(clip.head + clip.diverged + clip.tail,
                                   expected: "eof", expectedRebases: 0)
        let control = try await run(clip.head + clip.tail, expected: "eof", expectedRebases: 0)
        #expect(result.packetsWrittenCount == control.packetsWrittenCount)
    }

    @Test("a source ending inside a long exact overlap never publishes that overlap")
    func truncatedOverlapDoesNotReplayItsPrefix() async throws {
        let clip = try fixture()
        try await run(clip.head + clip.head, expected: "sourceReplay", expectedRebases: 0)
    }

    @Test("a read failure inside a confirmed overlap requests a fresh source")
    func failedOverlapDoesNotReplayItsPrefix() async throws {
        let clip = try fixture()
        try await run(clip.head + clip.head, expected: "sourceReplay", expectedRebases: 0,
                      failAtEnd: true)
    }

    @Test("a repeated overlap exceeding the packet bound never forwards its old media")
    func boundedOverlapDoesNotReplayItsPrefix() async throws {
        let clip = try fixture()
        var bytes = clip.head
        for _ in 0..<2_000 { bytes.append(clip.head) }
        try await run(bytes, expected: "sourceReplay", expectedRebases: 0,
                      mustLeaveUnreadBytes: true)
    }

    @Test("a short ambiguous match preserves a genuine source clock reset")
    func ambiguousOverlapKeepsNewMedia() async throws {
        let clip = try fixture(divergenceFrame: 1, divergenceFrames: 7)
        try await run(clip.head + clip.diverged + clip.tail, expected: "eof", expectedRebases: 1)
    }

    @Test("paired H.264/AAC replay continues only after both tracks finish the overlap")
    func pairedExactOverlap() async throws {
        // Leading AAC before the initial video gate was never accepted into replay history.
        // Replay the played A/V interval, not that unplayed join preroll.
        let clip = try fixture(data: Self.audioVideoFixture(), headFrames: 12, replayStartFrame: 2)
        try await run(clip.head + clip.replay + clip.tail, expected: "eof", expectedRebases: 0)
    }

    @Test("paired H.264/AAC divergence does not replay video or rebase either track")
    func pairedDivergentOverlap() async throws {
        let clip = try fixture(data: Self.audioVideoFixture(), divergenceFrame: 9,
                               headFrames: 12, replayStartFrame: 2)
        let result = try await run(clip.head + clip.diverged + clip.tail,
                                   expected: "eof", expectedRebases: 0)
        let control = try await run(clip.head + clip.tail, expected: "eof", expectedRebases: 0)
        #expect(result.packetsWrittenCount == control.packetsWrittenCount)
    }

    @Test("changed AAC at the first match or inside paired overlap continues without replay", arguments: [0, 150])
    func pairedAudioDivergence(packetIndex: Int) async throws {
        let clip = try fixture(data: Self.audioVideoFixture(), headFrames: 12, replayStartFrame: 2)
        var replay = clip.replay
        let adts = Data([0xFF, 0xF1, 0x4C])
        var offsets: [Int] = []
        var position = 0
        while let range = replay.range(of: adts, in: position..<replay.count) {
            offsets.append(range.lowerBound)
            position = range.upperBound
        }
        let offset = try #require(offsets.dropFirst(packetIndex).first)
        replay[offset + 2] ^= 0x02 // ADTS private bit: different bytes, same AAC configuration.
        let result = try await run(clip.head + replay + clip.tail, expected: "eof", expectedRebases: 0)
        let control = try await run(clip.head + clip.tail, expected: "eof", expectedRebases: 0)
        #expect(result.packetsWrittenCount == control.packetsWrittenCount)
    }

    @Test("a different paired programme with reused timestamps preserves every video packet")
    func differentPairedProgramme() async throws {
        let clip = try fixture(data: Self.audioVideoFixture(), divergenceFrame: 2,
                               divergenceFrames: 10, headFrames: 12, replayStartFrame: 2)
        var changed = clip.diverged
        var position = 0
        while let adts = changed.range(of: Data([0xFF, 0xF1, 0x4C]), in: position..<changed.count) {
            changed[adts.lowerBound + 2] ^= 0x02
            position = adts.upperBound
        }
        let result = try await run(clip.head + changed + clip.tail, expected: "eof", expectedRebases: 1)
        #expect(result.packetsWrittenCount == 26, "12 initial + 10 changed + 4 trailing pictures")
    }

    @Test("a clean outgoing PES before rollback cannot release the damaged video boundary")
    func corruptOutgoingVideoBeforeCleanTail() async throws {
        let clip = try fixture(data: Self.audioVideoFixture(), headFrames: 12, replayStartFrame: 2)
        var head = clip.head
        let aud = Data([0, 0, 0, 1, 9, 0xF0])
        let last = try #require(head.range(of: aud, options: .backwards))
        let previous = try #require(head.range(of: aud, options: .backwards, in: 0..<last.lowerBound))
        head[previous.lowerBound / 188 * 188 + 1] |= 0x80
        let capture = EngineLogCapture()
        defer { capture.end() }
        let result = try await run(head + clip.replay + clip.tail, expected: "eof", expectedRebases: 0)
        let control = try await run(clip.head + clip.tail, expected: "eof", expectedRebases: 0)
        #expect(result.packetsWrittenCount == control.packetsWrittenCount)
        #expect(!capture.matching("live damaged packet: stream=video action=discarded").isEmpty)
        #expect(capture.matching("live damaged packet: stream=video action=forwarded").isEmpty)
    }

    @Test("the damaged outgoing video boundary is withheld until its intact replay arrives")
    func corruptOutgoingVideoBoundary() async throws {
        let clip = try fixture(data: Self.audioVideoFixture(), headFrames: 12, replayStartFrame: 2)
        var head = clip.head
        let aud = try #require(head.range(of: Data([0, 0, 0, 1, 9, 0xF0]), options: .backwards))
        // TS transport-error indicator flags this PES without changing its compressed payload.
        head[aud.lowerBound / 188 * 188 + 1] |= 0x80
        let capture = EngineLogCapture()
        defer { capture.end() }
        let result = try await run(head + clip.replay + clip.tail, expected: "eof", expectedRebases: 0)
        let control = try await run(clip.head + clip.tail, expected: "eof", expectedRebases: 0)
        #expect(result.packetsWrittenCount == control.packetsWrittenCount)
        #expect(!capture.matching("live damaged boundary held:").isEmpty)
        #expect(!capture.matching("live damaged packet: stream=video action=discarded").isEmpty)
        #expect(capture.matching("live damaged packet: stream=video action=forwarded").isEmpty)
    }

    @Test("a corrupt first audio PES is held and discarded only after paired replay is verified")
    func corruptFirstAudioPES() async throws {
        let clip = try fixture(data: Self.audioVideoFixture(), headFrames: 12, replayStartFrame: 2)
        var replay = clip.replay
        let adts = try #require(replay.range(of: Data([0xFF, 0xF1, 0x4C])))
        let pes = try #require(replay.range(of: Data([0, 0, 1, 0xC0]), in: 0..<adts.lowerBound))
        let lengthOffset = pes.lowerBound + 4
        let length = Int(replay[lengthOffset]) * 256 + Int(replay[lengthOffset + 1]) + 1
        replay[lengthOffset] = UInt8(length >> 8)
        replay[lengthOffset + 1] = UInt8(length & 0xFF) // Truncated PES: one declared byte never arrives.
        let capture = EngineLogCapture()
        defer { capture.end() }
        let result = try await run(clip.head + replay + clip.tail, expected: "eof", expectedRebases: 0)
        let control = try await run(clip.head + clip.tail, expected: "eof", expectedRebases: 0)
        #expect(result.packetsWrittenCount == control.packetsWrittenCount)
        #expect(!capture.matching("live damaged packet: stream=audio action=held").isEmpty)
        #expect(!capture.matching("live damaged packet: stream=audio action=discarded").isEmpty)
    }

    @Test("paired replay interrupted by EOF or read failure never re-enters either timeline")
    func pairedInterruptedOverlap() async throws {
        let clip = try fixture(data: Self.audioVideoFixture(), headFrames: 12, replayStartFrame: 2)
        for failAtEnd in [false, true] {
            try await run(clip.head + clip.replay, expected: "sourceReplay", expectedRebases: 0,
                          failAtEnd: failAtEnd)
        }
    }


    /// 8 s, 16x16 H.264 Baseline at 2 fps + AAC-LC stereo at 48 kHz, no B-frames.
    /// Regenerate with the TinyTransportStreamFixture command plus
    /// `-f lavfi -i anullsrc=r=48000:cl=stereo -t 8 -c:a aac -b:a 16k`, then raw DEFLATE.
    private static func audioVideoFixture() throws -> Data {
        let compressed = Data(base64Encoded: [
            "3VpbbBRVGD7TCxRIhW0pFSvxLLeWS3dnZi+0hSm7FLp9gKTGxCeTZXb2bHfs7s50ZkpbJc2CjeHBYEy8EIzBS/AZjInxwUhV",
            "vCAieEEwxJQYMSZeSqJvJOt/FpJ2u0nrimH392xy5pw5Z2b/+c/3/9+cLxMJuVaQXdMbiDBJSE7IEeFWdmVfg7CotzdtsoEl",
            "jzDrgK4xURo52HMuV1klEiIrCDlVn7edCNNk8+mat8pt1D8skX6wvepUc97262SatPBq+XV4Cu/ud18ut3nzlkiYiIv7CRk/",
            "P879PkVINlvrJot/Vnl3yTSvB3adWfr9kwKsTzXJV6Gbax/nA8kLwksUjotqc7l91/b88t6Nq33vvLj1Cr267vc/RuWgn7ZT",
            "zbAYlYIBavlkWaYxXyAoBlQY6PPABO++/j2Rdj8NP9oDM+NMg4EewxxLsYRDZVH0tcuiHICTSccxu7zekZERzwE9zoyUmvFE",
            "BOIyrAEv/ydP0kmnYJ5hOrqRsbuopsZUTRGpxRKKROMsljK0QUXsgh9VM2pqzGa8R9NMiesqtYdj0BKpaY/BdKijVlyRPCJM",
            "gYqm9VEWj/J78SuilpoZYIoUpFrSMtJqFC6VqGOxVEq3YUbHaEdcc6ChDaWhjjM1/oSRYYosbZUkmlBtJwq2N5j2oG7ChXdu",
            "MmRGjUTCZvxCJ2nBRTYMpgxjUE1CJzpzzk5BGM+cEGnGyv+NpqdVh5uiZxxmpVSYBOdjqWFLHYtqRtpU80aBfxxL1TNwC5ho",
            "qXxOwlLTjN9qhOkDSceE1iAbg2FFvtOIpvUMdGyNge2+MLlb5GWYNszNyZvAXWsxO8kXTFM0K0HTMfAnXxHoKAFYCTrEn0AR",
            "PUFomtyY/FEdVYKd0LAdZip+qpuwOAABWDs/LPSQIpIsIJQdmeja2EaazkTCgiiE4MwZ8udtpF9Rczf3ZqtP3LpG9qoHtKDP",
            "I3kkUSa7aN3k/R18THj/lntFzf5nHixzJyIIkn3Xfi+9/BdPAXnGfxySx+VT42V4ggXLrNS3rPfmTOoLH6cNJwEz8h3M/JSf",
            "suQ7tZJwMV8HMOM7XH6P/zvMhIgL8TuBC/E7QcDuJ4Ln+Xsbq7OCsP7NQyW8f7Ajh6vbjr1K6M4sxKq/IFaXXcYUqwG0sRoW",
            "ggV+r/8Wk9+34fU7CQKvCk+PVjqvuha5inm1owAzy7/BhJlOtJgJkQbEvNqAmFe3OcCrPzx2j2N1VhQ2stdKItaJ+16PZcmh",
            "oxCrXQWx6voaU6xuRxurYdIB+b0qGKr0/N50VirO7zsKMNP4FSbMKHgxI3QX+L3pEia/70Tr9xBpRMyrjYh5tRP2q1VH15dt",
            "v7p6/WRp+1Vh6cY2UkenZumRt2O1+SKmWJXQxmqYdHFevVFX6bzaMvHwQnrk6i8xYQavHjlXW2q5gMnveLWlEFmJmFdXIubV",
            "7cCr1cqvZePVNT9eL227WpPXgZ/KFumRa77AFKuY9cgdwKvVL1ysdF519wwtpEc+dB4TZjDrkU2I83sT4vyu8Pz+29tly+/r",
            "3hBK3Dc9wPdNrVNFeqT7c0yxiliPnKPprTuHye+INT3SDbxas+dYpfNqa9VzxbzaXfDN1YbPijFToR9gcT0S7TdXIbIKMa+u",
            "QsyrO4FXa145WDZe3RRzl7hvSvJ904lskR7Z+imm/I5ZjxR5fv9rf6Xn9y2TpxfSIzd9ggkz/x89csvHmPyOWY9sRsyrzYh5",
            "VQJerd23u2y86nWHS9yvbub7Ve9UkR7ZfhZTrGLWI2Xg1dqTbZXOq1L20kJ6pPcjTJjBq0fO1ZakDzH5HbW29Gyo3KYXljwK",
            "1uZR4PtgHhT8DQ==",
        ].joined())!
        return try (compressed as NSData).decompressed(using: .zlib) as Data
    }
}
