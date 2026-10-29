import Foundation

/// Reorders compressed tracks on presentation DTS while preserving the original packet envelope.
/// One background consumer owns reads; source cancellation belongs to the caller. No source reader,
/// decoded PCM, public DVR window, or independent retention claim is created here.
final class CompressedAudioDelayAlignment: @unchecked Sendable {
    /// Media lane; foreign packets follow the video/source axis without an audio offset.
    enum Lane: UInt8, CaseIterable, Sendable { case video, audio, other }
    /// Finite titles retain their unmatched video tail; Live source loss cannot advertise a tail
    /// whose opposite track needs media from beyond EOF. Startup leading gates remain caller-owned.
    enum EndOfSourcePolicy: Sendable, Equatable { case finiteVideoTail, matchedInterval }
    /// Lossless input/output record, including a demuxer origin whose stream indices may alias.
    struct Packet: Sendable {
        /// Unchanged compressed bytes, side data, decode timestamps and duration.
        let record: SoftwareStoredPacket
        /// Track scheduling identity, independent of demuxer stream numbering.
        let lane: Lane
        /// Caller-owned demuxer identity (for example main0, companion1).
        let origin: Int
        /// Source-format/timeline generation; old queued packets drain before a new epoch.
        let epoch: UInt64
        /// Builds a record after source-order admission, recording and timeline preprocessing.
        init(record: SoftwareStoredPacket, lane: Lane, origin: Int = 0, epoch: UInt64 = 0) {
            self.record = record; self.lane = lane; self.origin = origin; self.epoch = epoch
        }
    }
    /// Bounded resident storage counters; reading these never waits for a blocking source read.
    struct Snapshot: Sendable {
        /// Logical disk residency, including consumed chunk prefixes and record headers.
        let residentBytes: Int
        /// Compressed records still waiting for delivery, including the per-lane heads.
        let queuedPackets: Int
        /// The single input source has reached EOF; queued tails still drain normally.
        let sourceEnded: Bool
        /// Effective audio extent observed at confirmed EOF, before any decoded representation.
        let audioEndSeconds: Double?
        /// Confirmed video edge keeps finite audio from extending beyond the selected picture.
        let videoEndSeconds: Double?
    }
    /// Failures propagate to the owning playback pipeline, never a silent packet drop.
    enum Failure: Error, Equatable, LocalizedError {
        /// The shared session allowance cannot retain the packets required for this correction.
        case capacityExceeded(requiredBytes: Int, availableBytes: Int)
        /// A persisted envelope is malformed or belongs to an unknown lane.
        case corruptRecord
        /// An actual disk write/read failed; replaying the source cannot restore storage capacity.
        case storageFailure(message: String)
        /// Explains whether more session/disk capacity is required or the temporary spool is damaged.
        var errorDescription: String? {
            switch self {
            case .capacityExceeded(let required, let available):
                return "Audio-delay buffering needs \(required) resident bytes, but the session allowance is \(available). Free storage or reduce the requested delay."
            case .corruptRecord:
                return "The compressed audio-delay spool is damaged. Reload the source to create a new spool."
            case .storageFailure(let message):
                return "Temporary storage for audio-delay buffering failed: \(message). Free storage and reload the source."
            }
        }
    }
    /// Immutable audio presentation offset; runtime changes reconstruct the owning stage.
    private let delaySeconds: Double
    /// Distinguishes intentional finite gaps from a Live stream's exhausted matching history.
    private let endOfSourcePolicy: EndOfSourcePolicy
    /// Hard ceiling owned by the existing session claim, not a second claim.
    private let byteBudget: Int
    /// Remaining session allowance after other cache users, sampled before each disk append.
    private let availableBytes: (() -> Int)?
    /// The only source-read operation; all source-order side effects belong inside this closure.
    private let readSource: () throws -> Packet?
    /// Detects stop, seek, source replacement and owner cancellation before/after source work.
    private let isCurrent: () -> Bool
    /// Reports numeric disk usage to the owning session, outside the snapshot lock.
    var onResidentBytesChanged: ((Int) -> Void)?
    /// Serializes worker-only read/close operations. Never acquire this lock on the main actor.
    private let operations = NSLock()
    /// Protects only numeric snapshots, so budget reporting cannot wait behind source I/O.
    private let stateLock = NSLock()
    /// Separate disk cursors bound RAM to one packet head per lane.
    private var stores: [Lane: SoftwarePacketDiskFIFO] = [:]
    /// One decoded envelope per lane; payloads remain compressed.
    private var heads: [Lane: Packet] = [:]
    /// Conservatively accounts compressed heads even when their consumed disk chunk was deleted.
    private var headResidentBytes: [Lane: Int] = [:]
    /// One new-epoch envelope waits in memory while its predecessor is retired.
    private var pendingEpochResidentBytes = 0
    /// A new epoch waits until every record from its predecessor has been delivered.
    private var pendingEpoch: Packet?
    /// The source epoch currently being drained.
    private var epoch: UInt64?
    /// Effective media coverage of this epoch; a discontinuity retires unmatched queued tails.
    private var coverage: [Lane: ClosedRange<Double>] = [:]
    /// Presentation endpoints account for reordered video while scheduling still uses DTS.
    private var presentationEnds: [Lane: Double] = [:]
    /// Source EOF differs from a temporary epoch barrier.
    private var ended = false
    /// True after worker teardown; subsequent reads are cancelled.
    private var closed = false
    /// Numeric residency published without exposing FIFO locks to retention accounting.
    private var residentBytes = 0
    /// Number of retained envelopes, including packets popped into lane heads.
    private var queuedPackets = 0
    /// Source EOF snapshot protected by stateLock.
    private var publishedEnded = false
    /// Confirmed-source extent is published with the numeric snapshot, not FIFO locks.
    private var publishedAudioEnd: Double?
    /// Effective video extent at EOF, using source samples rather than container-wide duration.
    private var publishedVideoEnd: Double?

    /// Creates bounded session-local disk queues. Call on a background worker.
    init(delaySeconds: Double, byteBudget: Int, endOfSourcePolicy: EndOfSourcePolicy = .finiteVideoTail,
         availableBytes: (() -> Int)? = nil,
         readSource: @escaping () throws -> Packet?, isCurrent: @escaping () -> Bool) throws {
        self.delaySeconds = delaySeconds
        self.endOfSourcePolicy = endOfSourcePolicy
        self.byteBudget = max(0, byteBudget)
        self.availableBytes = availableBytes
        self.readSource = readSource
        self.isCurrent = isCurrent
        do {
            for lane in Lane.allCases {
                stores[lane] = try SoftwarePacketDiskFIFO(chunkTargetBytes: min(4 << 20, max(64, byteBudget / 8)))
            }
        } catch {
            for store in stores.values { try? store.close() }
            throw error
        }
    }

    /// Reads accounting only; safe from retention-ledger callbacks and the main actor.
    var snapshot: Snapshot {
        stateLock.withLock { Snapshot(residentBytes: residentBytes, queuedPackets: queuedPackets, sourceEnded: publishedEnded, audioEndSeconds: publishedAudioEnd, videoEndSeconds: publishedVideoEnd) }
    }

    /// Delivers the next original packet in effective decode order, draining finite tails at EOF.
    /// Caller admission/recording/folding executes exactly once per source packet, before queuing.
    func read() throws -> Packet? {
        operations.lock()
        defer { operations.unlock() }
        while true {
            try checkCurrent()
            for lane in Lane.allCases where heads[lane] == nil {
                do {
                    if let data = try stores[lane]?.pop() {
                        heads[lane] = try Self.decode(data)
                        headResidentBytes[lane] = data.count + 8
                    }
                } catch { throw Failure.storageFailure(message: error.localizedDescription) }
            }
            publishResidency()
            let hasBothTracks = heads[.video] != nil && heads[.audio] != nil
            if hasBothTracks || ended || pendingEpoch != nil {
                if let lane = heads.keys.min(by: { effectiveDTS(heads[$0]!) < effectiveDTS(heads[$1]!) }),
                   let packet = heads.removeValue(forKey: lane) {
                    headResidentBytes.removeValue(forKey: lane)
                    stateLock.withLock { queuedPackets -= 1 }
                    publishResidency()
                    if (pendingEpoch != nil || (ended && endOfSourcePolicy == .matchedInterval)),
                       !belongsToMatchedEpoch(packet) { continue }
                    return packet
                }
                if let pending = pendingEpoch {
                    pendingEpoch = nil
                    pendingEpochResidentBytes = 0
                    epoch = pending.epoch
                    coverage.removeAll()
                    presentationEnds.removeAll()
                    try append(pending)
                    continue
                }
                if ended { return nil }
            }
            guard let packet = try readSource() else {
                ended = true
                stateLock.withLock { publishedEnded = true }
                continue
            }
            try checkCurrent()
            if let epoch, epoch != packet.epoch {
                let size = try Self.encode(packet).count + 8
                let current = stores.values.reduce(0) { $0 + $1.snapshot.diskByteCount }
                    + headResidentBytes.values.reduce(0, +)
                let available = min(byteBudget, max(0, availableBytes?() ?? byteBudget))
                if size > available || current > available - size {
                    throw Failure.capacityExceeded(requiredBytes: current.addingReportingOverflow(size).overflow ? Int.max : current + size,
                        availableBytes: available)
                }
                pendingEpoch = packet
                pendingEpochResidentBytes = size
                publishResidency()
            } else {
                epoch = packet.epoch
                try append(packet)
            }
        }
    }

    /// Releases disk resources after the owner has interrupted source reads. Worker-only.
    func close() throws {
        operations.lock()
        defer { operations.unlock() }
        closed = true
        heads.removeAll(); headResidentBytes.removeAll()
        pendingEpoch = nil; pendingEpochResidentBytes = 0
        var failure: (any Error)?
        for store in stores.values { do { try store.close() } catch { failure = error } }
        stateLock.withLock { residentBytes = 0; queuedPackets = 0 }
        onResidentBytesChanged?(0)
        if let failure { throw failure }
    }

    deinit { for store in stores.values { try? store.close() } }

    /// Rejects stale work even when a source read completes after cancellation.
    private func checkCurrent() throws {
        if closed || !isCurrent() || Task.isCancelled { throw CancellationError() }
    }
    /// Effective DTS is used only for ordering; packet PTS/DTS are returned untouched.
    private func effectiveDTS(_ packet: Packet) -> Double {
        let record = packet.record
        let ticks = record.dts == Int64.min ? record.pts : record.dts
        guard ticks != Int64.min, record.timeBaseDenominator > 0 else { return -.infinity }
        return Double(ticks) * Double(record.timeBaseNumerator) / Double(record.timeBaseDenominator)
            + (packet.lane == .audio ? delaySeconds : 0)
    }
    /// Enforces total logical residency before writing, including envelope and FIFO headers.
    private func append(_ packet: Packet) throws {
        let data = try Self.encode(packet)
        let current = stores.values.reduce(0) { $0 + $1.snapshot.diskByteCount }
            + headResidentBytes.values.reduce(0, +) + pendingEpochResidentBytes
        let available = min(byteBudget, max(0, availableBytes?() ?? byteBudget))
        let (required, overflow) = current.addingReportingOverflow(data.count + 8)
        if overflow || required > available {
            throw Failure.capacityExceeded(requiredBytes: overflow ? Int.max : required, availableBytes: available)
        }
        do { try stores[packet.lane]?.append(data) }
        catch { throw Failure.storageFailure(message: error.localizedDescription) }
        stateLock.withLock { queuedPackets += 1 }
        let start = effectiveDTS(packet)
        let record = packet.record
        let duration = record.timeBaseDenominator > 0
            ? max(0, Double(record.duration) * Double(record.timeBaseNumerator) / Double(record.timeBaseDenominator)) : 0
        let presentationTicks = record.pts == Int64.min ? record.dts : record.pts
        if presentationTicks != Int64.min, record.timeBaseDenominator > 0 {
            let end = Double(presentationTicks) * Double(record.timeBaseNumerator) / Double(record.timeBaseDenominator)
                + (packet.lane == .audio ? delaySeconds : 0) + duration
            presentationEnds[packet.lane] = max(presentationEnds[packet.lane] ?? end, end)
        }
        if start.isFinite {
            let previous = coverage[packet.lane]
            coverage[packet.lane] = min(previous?.lowerBound ?? start, start)...max(previous?.upperBound ?? start, start + duration)
        }
        publishResidency()
    }
    /// Old-epoch packets with no matching opposite track cannot be muxed against a new format.
    /// Retire only the queued unmatched portion at a discontinuity; finite EOF still drains video
    /// tails normally. Caller startup gates decide whether earlier leading gaps are presentable.
    private func belongsToMatchedEpoch(_ packet: Packet) -> Bool {
        guard let video = coverage[.video], let audio = coverage[.audio] else { return false }
        let lower = max(video.lowerBound, audio.lowerBound)
        let upper = min(video.upperBound, audio.upperBound)
        let time = effectiveDTS(packet)
        return lower < upper && time >= lower && time < upper
    }

    /// Publishes cached numeric counters without retaining storage locks afterward.
    private func publishResidency() {
        let bytes = stores.values.reduce(0) { $0 + $1.snapshot.diskByteCount }
            + headResidentBytes.values.reduce(0, +) + pendingEpochResidentBytes
        stateLock.withLock {
            residentBytes = bytes
            publishedAudioEnd = ended ? presentationEnds[.audio] : nil
            publishedVideoEnd = ended ? presentationEnds[.video] : nil
        }
        onResidentBytesChanged?(bytes)
    }
    /// Persists only fixed scheduling metadata before the existing lossless packet envelope.
    private static func encode(_ packet: Packet) throws -> Data {
        var data = Data([packet.lane.rawValue])
        var origin = Int64(packet.origin).littleEndian
        var epoch = packet.epoch.littleEndian
        withUnsafeBytes(of: &origin) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &epoch) { data.append(contentsOf: $0) }
        data.append(try packet.record.encoded())
        return data
    }
    /// Restores scheduling metadata without discarding original compressed packet side data.
    private static func decode(_ data: Data) throws -> Packet {
        guard data.count >= 17, let lane = Lane(rawValue: data[0]) else { throw Failure.corruptRecord }
        let origin = data.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(fromByteOffset: 1, as: Int64.self)) }
        let epoch = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 9, as: UInt64.self)) }
        return Packet(record: try SoftwareStoredPacket.decode(Data(data.dropFirst(17))), lane: lane, origin: Int(origin), epoch: epoch)
    }
}
