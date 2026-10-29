import Foundation
import Testing
@testable import AetherEngine

/// Verifies real disk envelopes and finite-input ordering independently of either renderer.
@Suite(.serialized)
struct CompressedAudioDelayAlignmentTests {
    /// Minimal lossless record with recognizable payload and side-data identity.
    private static func packet(_ time: Int64, lane: CompressedAudioDelayAlignment.Lane, epoch: UInt64 = 0,
                               payload: Int = 16, scale: Int32 = 1) -> CompressedAudioDelayAlignment.Packet {
        .init(record: .init(pts: time, dts: time, duration: 1, position: time,
            streamIndex: lane == .video ? 0 : 1, flags: 1, timeBaseNumerator: 1,
            timeBaseDenominator: scale, bytes: Data(repeating: UInt8(truncatingIfNeeded: time), count: payload),
            sideData: [.init(type: 1, bytes: Data([1, 2, 3]))]), lane: lane, origin: lane == .audio ? 1 : 0, epoch: epoch)
    }

    /// Actual disk queues retain original bytes and decode order at both range limits and threshold.
    @Test(arguments: [2.5, 3.0, -3.0, 30.0, -30.0, 180.0, -180.0])
    func mergesPresentationDTSWithoutChangingPackets(delay: Double) async throws {
        let job = ProbeTestJob {
            let source = (0..<200).flatMap { time in
                [Self.packet(Int64(time), lane: .video), Self.packet(Int64(time), lane: .audio)]
            }
            var cursor = 0
            let alignment = try CompressedAudioDelayAlignment(delaySeconds: delay, byteBudget: 1 << 20,
                readSource: { if cursor == source.count { return nil }; defer { cursor += 1 }; return source[cursor] },
                isCurrent: { true })
            defer { try? alignment.close() }
            var output: [CompressedAudioDelayAlignment.Packet] = []
            while let packet = try alignment.read() { output.append(packet) }
            #expect(output.count == source.count)
            let times = output.map { Double($0.record.dts) + ($0.lane == .audio ? delay : 0) }
            #expect(zip(times, times.dropFirst()).allSatisfy { $0 <= $1 })
            for lane in [CompressedAudioDelayAlignment.Lane.video, .audio] {
                #expect(output.filter { $0.lane == lane }.map(\.record) == source.filter { $0.lane == lane }.map(\.record))
            }
            #expect(output.filter { $0.lane == .audio }.allSatisfy { $0.origin == 1 })
            #expect(alignment.snapshot.sourceEnded)
        }
        try await job.outcome().get()
    }

    /// Source origins and independent audio/video tick scales compare on seconds, not raw ticks.
    @Test
    func mergesNonzeroOriginAndDistinctTimeBases() async throws {
        let job = ProbeTestJob {
            let source = [Self.packet(3600 * 90000, lane: .video, scale: 90000),
                          Self.packet(3600 * 48000, lane: .audio, scale: 48000),
                          Self.packet(3601 * 90000, lane: .video, scale: 90000),
                          Self.packet(3601 * 48000, lane: .audio, scale: 48000)]
            var cursor = 0
            let alignment = try CompressedAudioDelayAlignment(delaySeconds: -3, byteBudget: 4096,
                readSource: { if cursor == source.count { return nil }; defer { cursor += 1 }; return source[cursor] },
                isCurrent: { true })
            defer { try? alignment.close() }
            var output: [CompressedAudioDelayAlignment.Packet] = []
            while let packet = try alignment.read() { output.append(packet) }
            #expect(output.map(\.lane) == [.audio, .audio, .video, .video])
            #expect(output[0].record.dts == 3600 * 48000)
            #expect(output[2].record.dts == 3600 * 90000)
        }
        try await job.outcome().get()
    }

    /// A new codec/PCR epoch cannot interleave its packets ahead of retained old-epoch packets.
    @Test
    func drainsEpochBeforeAcceptingReplacement() async throws {
        let job = ProbeTestJob {
            let source = [Self.packet(100, lane: .video), Self.packet(100, lane: .audio),
                          Self.packet(101, lane: .video), Self.packet(0, lane: .video, epoch: 1),
                          Self.packet(0, lane: .audio, epoch: 1)]
            var cursor = 0
            let alignment = try CompressedAudioDelayAlignment(delaySeconds: 0.5, byteBudget: 4096,
                readSource: { if cursor == source.count { return nil }; defer { cursor += 1 }; return source[cursor] },
                isCurrent: { true })
            defer { try? alignment.close() }
            var epochs: [UInt64] = []
            while let packet = try alignment.read() { epochs.append(packet.epoch) }
            #expect(epochs == [0, 0, 0, 1, 1])
        }
        try await job.outcome().get()
    }

    /// A short source epoch cannot leave three minutes of unmatched old media ahead of new config.
    @Test(arguments: [180.0, -180.0])
    func retiresUnmatchedQueuedEpochTail(delay: Double) async throws {
        let job = ProbeTestJob {
            let source = (0..<60).flatMap { time in [Self.packet(Int64(time), lane: .video), Self.packet(Int64(time), lane: .audio)] }
                + [Self.packet(0, lane: .video, epoch: 1), Self.packet(0, lane: .audio, epoch: 1)]
            var cursor = 0
            let alignment = try CompressedAudioDelayAlignment(delaySeconds: delay, byteBudget: 1 << 20,
                readSource: { if cursor == source.count { return nil }; defer { cursor += 1 }; return source[cursor] },
                isCurrent: { true })
            defer { try? alignment.close() }
            var output: [CompressedAudioDelayAlignment.Packet] = []
            while let packet = try alignment.read() { output.append(packet) }
            if delay > 0 { #expect(!output.contains { $0.epoch == 0 && $0.lane == .audio }) }
            else { #expect(!output.contains { $0.epoch == 0 && $0.lane == .video }) }
            #expect(output.contains { $0.epoch == 1 })
        }
        try await job.outcome().get()
    }

    /// Live EOF retires only unmatched queued media; finite EOF deliberately retains its video
    /// tail. Startup filtering models each route's fresh-anchor contract before shared scheduling.
    @Test(arguments: [180.0, -180.0])
    func liveEOFDoesNotReleaseUnmatchedTails(delay: Double) async throws {
        let job = ProbeTestJob {
            let source = (0..<257).flatMap { time -> [CompressedAudioDelayAlignment.Packet] in
                var packets: [CompressedAudioDelayAlignment.Packet] = []
                if Double(time) >= max(delay, 0) { packets.append(Self.packet(Int64(time), lane: .video)) }
                if Double(time) >= max(-delay, 0) { packets.append(Self.packet(Int64(time), lane: .audio)) }
                return packets
            }
            for policy in [CompressedAudioDelayAlignment.EndOfSourcePolicy.matchedInterval, .finiteVideoTail] {
                var cursor = 0
                let alignment = try CompressedAudioDelayAlignment(delaySeconds: delay, byteBudget: 1 << 20,
                    endOfSourcePolicy: policy,
                    readSource: { if cursor == source.count { return nil }; defer { cursor += 1 }; return source[cursor] },
                    isCurrent: { true })
                defer { try? alignment.close() }
                var output: [CompressedAudioDelayAlignment.Packet] = []
                while let packet = try alignment.read() { output.append(packet) }
                if policy == .matchedInterval {
                    let lower = max(delay, 0)
                    let upper = 257 + min(delay, 0)
                    #expect(output.allSatisfy {
                        let time = Double($0.record.dts) + ($0.lane == .audio ? delay : 0)
                        return time >= lower && time < upper
                    })
                    #expect(output.filter { $0.lane == .video }.count == 77)
                    #expect(output.filter { $0.lane == .audio }.count == 77)
                } else if delay < 0 {
                    #expect(output.last { $0.lane == .video }?.record.pts == 256)
                }
            }
        }
        try await job.outcome().get()
    }

    /// Strict disk residency includes envelope and record overhead; failure is actionable.
    @Test
    func refusesCapacityWithoutDroppingPacketsSilently() async throws {
        let job = ProbeTestJob {
            let alignment = try CompressedAudioDelayAlignment(delaySeconds: 180, byteBudget: 128,
                readSource: { Self.packet(0, lane: .video, payload: 1024) }, isCurrent: { true })
            defer { try? alignment.close() }
            do { _ = try alignment.read(); Issue.record("Capacity failure was not propagated") }
            catch let error as CompressedAudioDelayAlignment.Failure {
                #expect(error.localizedDescription.contains("Free storage or reduce"))
                #expect(alignment.snapshot.residentBytes <= 128)
            }
        }
        try await job.outcome().get()
    }

    /// Cancellation during a source read cannot publish its returned record into a retired owner.
    @Test
    func rejectsSourceCompletionAfterCancellation() async throws {
        let job = ProbeTestJob {
            var current = true
            let alignment = try CompressedAudioDelayAlignment(delaySeconds: 180, byteBudget: 4096,
                readSource: { current = false; return Self.packet(0, lane: .video) }, isCurrent: { current })
            defer { try? alignment.close() }
            do { _ = try alignment.read(); Issue.record("Stale source completion was delivered") }
            catch is CancellationError { #expect(alignment.snapshot.queuedPackets == 0) }
        }
        try await job.outcome().get()
    }
}
