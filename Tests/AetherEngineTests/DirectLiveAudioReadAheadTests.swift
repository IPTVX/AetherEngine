import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Ordinary software Live must not make its sole source reader wait for video queue readiness.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct DirectLiveAudioReadAheadTests {
    // Failure modes:
    // - The video renderer fills and the sole reader never reaches subsequent audio packets.
    // - Compressed video grows without a byte bound while audio reads ahead.
    // - Stop/replacement leaves a parked producer running or enables public DVR accidentally.

    /// Models interleaved source packets and a closed video renderer using the actual decoder/output.
    @Test
    func audioContinuesWhileVideoGateIsClosed() async throws {
        let reader = ProbeRecordingReader(data: try LongGOPTransportStreamFixture.data())
        let engine = try AetherEngine()
        let ready = ProbeTestBox(false)
        let delivered = ProbeTestBox(0)
        defer { ready.update { $0 = true }; engine.stop() }
        try await engine.load(source: .custom(reader, formatHint: "mpegts"), options: LoadOptions(
            isLive: true, autoplay: false, preferredDecodePath: .software))
        try #require(engine.videoRoute == .software)
        let host = try #require(engine.softwareHost)
        host.videoRendererForTesting.readyForMoreMediaDataForTesting = { ready.value }
        host.observeDeliveredAudioForTesting { _, _ in delivered.update { $0 += 1 } }

        engine.play()
        try #require(try await waitFor(upTo: .seconds(2)) { delivered.value >= 24 },
            "More than one audio PES burst must progress while the video gate remains closed")
        #expect(host.videoRendererForTesting.takeCadence().handedOver == 0)
        #expect(engine.liveWindow?.windowSeconds == nil)
        try #require(try await waitFor(upTo: .seconds(3)) { engine.currentTime > 0.5 })
        engine.pause()
        try await Task.sleep(for: .milliseconds(100))
        let count = delivered.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(delivered.value == count)
        let source = try #require(host.directLiveReadAheadForTesting)
        #expect(source.packets.snapshot.residentBytes <= source.parkedByteLimit)
        #expect(!host.servesPacketCacheStills)
        ready.update { $0 = true }
        engine.play()
        try #require(try await waitFor(upTo: .seconds(3)) {
            host.videoRendererForTesting.takeCadence().handedOver > 1
        })
    }

    /// A source worker held inside I/O cannot prevent already-queued compressed video from rendering.
    @Test
    func readyVideoProgressesWhileSourceReadIsHeld() async throws {
        let edge = ProbeTestGate()
        let producerReads = ProbeTestBox(0)
        let ready = ProbeTestBox(false)
        let reader = ProbeRecordingReader(data: try LongGOPTransportStreamFixture.data(), chunkSize: 4096,
            afterRead: {
                if Thread.current.name == "AetherEngine.SoftwarePacketReadAhead.producer" {
                    producerReads.update { $0 += 1 }
                    if producerReads.value >= 2 { edge.wait() }
                }
            }, afterCancel: { edge.open() })
        let engine = try AetherEngine()
        defer { edge.open(); ready.update { $0 = true }; engine.stop() }
        try await engine.load(source: .custom(reader, formatHint: "mpegts"), options: LoadOptions(
            isLive: true, autoplay: false, preferredDecodePath: .software))
        let host = try #require(engine.softwareHost)
        host.videoRendererForTesting.readyForMoreMediaDataForTesting = { ready.value }
        engine.play()
        try #require(try await waitFor(upTo: .seconds(5)) { edge.entered })
        let reads = producerReads.value
        ready.update { $0 = true }
        try #require(try await waitFor(upTo: .seconds(2)) {
            host.videoRendererForTesting.takeCadence().handedOver >= 20
        })
        #expect(producerReads.value == reads && !edge.isOpen)
        engine.stop()
        #expect(edge.isOpen)
        #expect(engine.state == .idle)
    }

    /// Closing is idempotent but cannot release storage reserved by a still-blocked source worker.
    @Test
    func closeKeepsReservationUntilHeldSourceRetires() async throws {
        let edge = ProbeTestGate()
        let calls = ProbeTestBox(0)
        let ledger = RetentionClaims()
        let reader = ProbeRecordingReader(data: try LongGOPTransportStreamFixture.data(), chunkSize: 4096,
            afterRead: {
                if Thread.current.name == "AetherEngine.SoftwarePacketReadAhead.producer" {
                    calls.update { $0 += 1 }
                    if calls.value >= 2 { edge.wait() }
                }
            }, afterCancel: { edge.open() })
        let demuxer = Demuxer()
        defer { edge.open(); demuxer.close() }
        var source: DirectLiveAudioReadAhead? = try await BlockingWork.detached {
            try demuxer.open(reader: reader, formatHint: "mpegts", isLive: true)
            return try DirectLiveAudioReadAhead(demuxer: demuxer, videoIndex: demuxer.videoStreamIndex,
                audioIndex: demuxer.audioStreamIndex, requestedBytes: 8 << 20, retentionClaims: ledger)
        }.value
        defer { source?.close() }
        weak var worker = source?.packets
        source?.packets.start()
        try #require(try await waitFor(upTo: .seconds(3)) { edge.entered })
        source?.close()
        source?.close()
        source = nil
        #expect(ledger.claim(volumeAvailableBytes: nil) { _ in 0 }.heldBackBytes > 0,
            "The stopped source still owns its FIFO/transient reservation while I/O is held")
        edge.open()
        try #require(try await waitFor(upTo: .seconds(3)) { worker == nil })
        #expect(ledger.claim(volumeAvailableBytes: nil) { _ in 0 }.heldBackBytes == 0)
    }

    /// Small offsets still reach the real renderer while ordinary Live uses the bounded worker.
    @Test(arguments: [-0.5, 0.5])
    func smallDelayKeepsDeliveredOffset(delay: Double) async throws {
        let reader = ProbeRecordingReader(data: try LongGOPTransportStreamFixture.data())
        let engine = try AetherEngine()
        let timing = ProbeTestBox<[(Double, Double)]>([])
        defer { engine.stop() }
        try await engine.load(source: .custom(reader, formatHint: "mpegts"), options: LoadOptions(
            isLive: true, autoplay: false, audioDelaySeconds: delay, preferredDecodePath: .software))
        let host = try #require(engine.softwareHost)
        host.observeDeliveredAudioForTesting { source, output in timing.update { $0.append((source, output)) } }
        engine.play()
        try #require(try await waitFor(upTo: .seconds(3)) { !timing.value.isEmpty })
        let pair = try #require(timing.value.first)
        #expect(abs(pair.1 - pair.0 - delay) < 0.001)
        #expect(host.directLiveReadAheadForTesting != nil)
        #expect(engine.liveWindow?.windowSeconds == nil)
    }

    /// An idle timeout happens before pop and does not mean EOF or invalidate a current packet.
    @Test
    func idleConsumerDoesNotPopOrEndTheSource() async throws {
        let fifo = try SoftwarePacketDiskFIFO(retainConsumed: false)
        let entered = ProbeTestGate()
        let calls = ProbeTestBox(0)
        let record = SoftwareStoredPacket(pts: 10, dts: 10, duration: 1, position: 0,
            streamIndex: 0, flags: 1, timeBaseNumerator: 1, timeBaseDenominator: 25,
            bytes: Data([1, 2, 3]), sideData: [])
        let source = SoftwarePacketReadAhead(video: .init(index: 0, numerator: 1, denominator: 25),
            audio: nil, byteBudget: 1 << 20, forwardSeconds: 4,
            maximumResidentBytes: 1 << 20, forwardOnly: true, initialSourceClock: 0, fifo: fifo) { _ in
                calls.update { $0 += 1 }
                if calls.value == 1 { entered.wait(); return record }
                return nil
            }
        defer { entered.open(); source.close() }
        source.start()
        try #require(try await waitFor(upTo: .seconds(2)) { entered.entered })
        #expect(throws: SoftwarePacketReadAhead.ReadError.idle) { _ = try source.read(maximumWait: 0) }
        #expect(!source.snapshot.sourceEnded && source.snapshot.packetCount == 0)
        entered.open()
        try #require(try await waitFor(upTo: .seconds(2)) { source.snapshot.packetCount == 1 })
        #expect(try source.read(maximumWait: 0) == record)
        try #require(try await waitFor(upTo: .seconds(2)) { source.snapshot.sourceEnded })
        #expect(try source.read(maximumWait: 0) == nil)
    }

    /// Packet accounting includes side data and referenced allocation capacity, not payload alone.
    @Test
    func compressedCostIncludesSideData() throws {
        let packet = try #require(av_packet_alloc())
        defer { var owned = Optional(packet); av_packet_free(&owned) }
        try #require(av_new_packet(packet, 1024) == 0)
        let before = DirectLiveAudioReadAhead.packetBytes(packet)
        _ = try #require(av_packet_new_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, 4096))
        #expect(DirectLiveAudioReadAhead.packetBytes(packet) >= before + 4096)
    }

    /// A damaged reconnect quarantine must share the byte bound instead of retaining arbitrary packets.
    @Test
    func replayQuarantineRejectsExcessResidency() throws {
        let admission = LiveReplayPacketReader(videoIndex: 0, audioIndex: 1,
            videoTimeBase: 0.1, audioTimeBase: 0.1, residentLimit: 128,
            retainedSize: { DirectLiveAudioReadAhead.packetBytes($0) })
        var index = 0
        #expect(throws: LiveReplayPacketReader.Failure.retentionExceeded) {
            while let packet = try admission.read(from: {
                if index > 80 { return nil }
                let packet = try #require(av_packet_alloc())
                try #require(av_new_packet(packet, 1) == 0)
                packet.pointee.stream_index = Int32(index % 2)
                packet.pointee.pts = Int64(index / 2)
                packet.pointee.dts = packet.pointee.pts
                packet.pointee.data[0] = 1
                if index == 80 { packet.pointee.flags |= AV_PKT_FLAG_CORRUPT }
                index += 1
                return packet
            }) {
                var owned = Optional(packet)
                av_packet_free(&owned)
            }
        }
    }

    /// Entering/leaving large alignment retires its old source, while signed small offsets retain it.
    @Test
    func alignmentTransitionsPreserveDirectLiveOwnership() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("direct-live-delay-\(UUID()).ts")
        try LongAudioDelayTransportStreamFixture.write(to: url)
        let engine = try AetherEngine()
        defer { engine.stop(); try? FileManager.default.removeItem(at: url) }
        try await engine.load(url: url, options: LoadOptions(isLive: true, autoplay: false,
            audioDelaySeconds: 0.5, preferredDecodePath: .software))
        let initial = try #require(engine.softwareHost?.directLiveReadAheadForTesting)
        engine.setAudioDelay(2)
        #expect(engine.softwareHost?.directLiveReadAheadForTesting === initial)
        for delay in [180.0, -180.0, -2.0, 0.0] {
            engine.setAudioDelay(delay)
            try #require(try await waitFor(upTo: .seconds(10)) {
                engine.liveAudioDelayRejoinTask == nil && engine.state == .paused
            })
            #expect(engine.audioDelaySeconds == delay)
            #expect(engine.liveWindow?.windowSeconds == nil)
            #expect((engine.softwareHost?.directLiveReadAheadForTesting != nil) == (abs(delay) <= 2))
        }
        #expect(throws: SoftwarePacketReadAhead.ReadError.closed) { _ = try initial.packets.read(maximumWait: 0) }
    }

    /// Finite Live keeps its tail rather than ending when the new source worker reaches EOF early.
    @Test
    func finiteLiveDrainsBeforeEnding() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        try await engine.load(source: .custom(ProbeRecordingReader(data: try LongGOPTransportStreamFixture.data()),
            formatHint: "mpegts"), options: LoadOptions(isLive: true, autoplay: true, preferredDecodePath: .software))
        engine.setRate(2)
        try #require(try await waitFor(upTo: .seconds(25)) { engine.state == .ended || engine.errorInfo != nil })
        #expect(engine.errorInfo == nil && engine.state == .ended)
        #expect(engine.currentTime > 30)
        #expect(engine.softwareHost?.videoRendererForTesting.takeCadence().handedOver ?? 0 > 100)
    }
}
