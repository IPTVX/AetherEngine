import Foundation
import AetherLibavcodec
import AetherLibavutil

/// A single forward-only source worker for ordinary software Live. It shares the already-open
/// demuxer/connection, exposes no seek window, and reserves one bounded allowance for disk,
/// parked compressed video and transient packet-envelope copies. No decoded media is retained.
final class DirectLiveAudioReadAhead: @unchecked Sendable {
    /// The source FIFO, with consumed records discarded rather than retained as DVR history.
    let packets: SoftwarePacketReadAhead
    /// One eighth of the allowance bounds parked video; an equal partition bounds source records.
    let parkedByteLimit: Int
    /// Maximum single packet allocation, including side data and envelope headroom.
    let packetByteLimit: Int
    /// One shared reservation: replay quarantine uses a quarter; bounded transient copies a half.
    private let claim: RetentionClaims.Claim
    /// Thread-safe parked-byte accounting independent of decoder or demuxer locks.
    private let usage = AudioDelaySpoolUsage()
    /// Stable owner for the parked-video accounting slot.
    private let owner = UUID()

    /// Builds off-main before any source worker starts; failure is explicit rather than changing route.
    /// The default process ledger shares storage with other sessions; an isolated ledger supports
    /// deterministic lifecycle verification without changing source or renderer behavior.
    init(demuxer: Demuxer, videoIndex: Int32, audioIndex: Int32, requestedBytes: Int?,
         retentionClaims: RetentionClaims = .shared) throws {
        guard let video = demuxer.stream(at: videoIndex), let audio = demuxer.stream(at: audioIndex) else {
            throw Failure.unavailable
        }
        let vb = video.pointee.time_base, ab = audio.pointee.time_base
        let temp = FileManager.default.temporaryDirectory
        let available = (try? temp.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
        let claim = retentionClaims.claim(volumeAvailableBytes: available) {
            min(64 << 20, SoftwarePlaybackHost.packetCacheBudgetBytes(requestedBytes: requestedBytes,
                availableBytes: $0, capRelaxed: false))
        }
        guard claim.bytes >= 4096 else { claim.release(); throw Failure.unavailable }
        self.claim = claim
        parkedByteLimit = claim.bytes / 8
        packetByteLimit = claim.bytes / 8
        let maximumPacketBytes = packetByteLimit
        // Quarantined replay packets get a separate quarter of this same reservation.
        let admission = LiveReplayPacketReader(videoIndex: videoIndex, audioIndex: audioIndex,
            videoTimeBase: av_q2d(vb), audioTimeBase: av_q2d(ab),
            residentLimit: claim.bytes / 4, retainedSize: { Self.packetBytes($0) })
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: min(4 << 20, parkedByteLimit),
            retainConsumed: false, maximumResidentBytes: parkedByteLimit)
        packets = SoftwarePacketReadAhead(
            video: .init(index: videoIndex, numerator: vb.num, denominator: vb.den),
            audio: .init(index: audioIndex, numerator: ab.num, denominator: ab.den),
            byteBudget: claim.bytes / 8, forwardSeconds: AudioLookaheadPolicy.targetLeadSeconds,
            maximumResidentBytes: claim.bytes / 8, forwardOnly: true,
            initialSourceClock: demuxer.resolvedSourceStartOrigin, fifo: fifo
        ) { [claim] isCurrent in
            // The producer owns this same reservation until its FIFO cleanup completes. The
            // consumer owner retains it too, until all parked video has been freed.
            defer { withExtendedLifetime(claim) {} }
            guard let packet = try admission.read(isCurrent: isCurrent, from: {
                guard let packet = try demuxer.readPacket(isCurrent: isCurrent) else { return nil }
                let bytes = Self.packetBytes(packet)
                if bytes > maximumPacketBytes {
                    var oversized = Optional(packet)
                    av_packet_free(&oversized)
                    throw Failure.packetTooLarge(bytes, maximumPacketBytes)
                }
                return packet
            }) else { return nil }
            defer { av_packet_unref(packet); av_packet_free_safe(packet) }
            return try SoftwareStoredPacket(copying: packet)
        }
        let usage = self.usage
        let packets = self.packets
        let transientAllowance = claim.bytes * 3 / 4
        claim.track { [weak packets] in
            (packets?.snapshot.residentBytes ?? 0) + usage.total + transientAllowance
        }
    }

    /// Includes actual referenced buffer capacity, side-data storage and conservative envelope headers.
    static func packetBytes(_ packet: UnsafePointer<AVPacket>) -> Int {
        var bytes = 512 + max(Int(max(0, packet.pointee.size)), Int(packet.pointee.buf?.pointee.size ?? 0))
        if let side = packet.pointee.side_data {
            for index in 0..<Int(max(0, packet.pointee.side_data_elems)) {
                let addition = Int(side[index].size) + SoftwareStoredPacket.sideDataHeaderBytes
                if addition > Int.max - bytes { return Int.max }
                bytes += addition
            }
        }
        return bytes
    }

    /// Reports actual parked residency into this same session reservation.
    func noteParkedBytes(_ bytes: Int) { usage.set(bytes, for: owner) }

    /// Retires the producer before normal host Demuxer.close cancels and joins its source read.
    /// The reservation is dropped only after both the consumer owner and producer/FIFO retire;
    /// releasing it here could let a replacement spend the old worker's still-resident allowance.
    func close() { packets.close() }

    /// Failures identify an unsatisfiable compressed span rather than silently losing video/audio.
    enum Failure: Error, LocalizedError {
        case unavailable
        case packetTooLarge(Int, Int)
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Live audio read-ahead requires a usable session cache allowance and temporary storage. Increase the cache allowance or free storage and retry."
            case .packetTooLarge(let bytes, let limit):
                return "A compressed Live packet needs \(bytes) bytes, exceeding its \(limit)-byte allowance. Increase the session cache allowance and retry."
            }
        }
    }
}
