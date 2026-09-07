import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// Enabled only by a healthy head whose IDR offset agrees with the container edit/index axis.
/// Healthy packets remain a zero-hold fast path. A zero-offset IDR starts one bounded sequence
/// probe; all interleaved packets are owned until its complete POC permutation is established.
/// DTS NEVER changes, so an already published keyframe index remains valid across region changes.
final class H264PartialCompositionRepairSession {
    private struct Entry {
        let packet: UnsafeMutablePointer<AVPacket>
        let poc: Int64?
    }
    enum RepairError: Error { case sequenceNoLongerRepairable }
    private let streamIndex: Int32
    private let timeBase: AVRational
    private let lead: Int64
    private let framing: VideoNALFraming
    private let reader: H264PictureOrderReader
    private var pending: [Entry] = []
    private var ready: [UnsafeMutablePointer<AVPacket>] = []
    private var readyIndex = 0
    private var bytes = 0
    private var videoCount = 0
    private var confirmed = false
    private var failed = false
    private var repairedCount = 0
    private var sampleCount = 0
    private var heldCount = 0
    private var heldBytes = 0
    private var regressions = 0
    private(set) var reason = "composition_offsets_present"

    init?(stream: UnsafeMutablePointer<AVStream>, streamIndex: Int32, presentationLead: Int64) {
        guard presentationLead > 0, let par = stream.pointee.codecpar,
              (1...16).contains(par.pointee.video_delay),
              let reader = H264PictureOrderReader(codecParameters: par, timeBase: stream.pointee.time_base)
        else { return nil }
        self.reader = reader
        self.streamIndex = streamIndex
        lead = presentationLead
        timeBase = stream.pointee.time_base
        framing = A53SEIParser.nalFraming(codec: .h264, extradata: par.pointee.extradata, size: Int(par.pointee.extradata_size))
    }

    deinit { releasePackets() }
    var hasDecision: Bool { reason != "composition_offsets_present" }

    private func isIDR(_ packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        guard packet.pointee.flags & AV_PKT_FLAG_KEY != 0,
              let data = packet.pointee.data, packet.pointee.size > 0 else { return false }
        var result = false
        A53SEIParser.forEachNAL(data, Int(packet.pointee.size), framing) { nal, size in
            if size > 0, nal[0] & 0x80 == 0, nal[0] & 31 == 5 { result = true }
        }
        return result
    }

    func ingest(_ packet: UnsafeMutablePointer<AVPacket>) throws -> Bool {
        if failed {
            var owned: UnsafeMutablePointer<AVPacket>? = packet; trackedPacketFree(&owned)
            throw RepairError.sequenceNoLongerRepairable
        }
        if packet.pointee.stream_index != streamIndex {
            guard !pending.isEmpty else { return false }
            append(packet, poc: nil)
            try checkBounds()
            return true
        }
        let idr = isIDR(packet)
        if idr, videoCount > 0 {
            do { try finishSequence(nextDTS: packet.pointee.dts) }
            catch { var owned: UnsafeMutablePointer<AVPacket>? = packet; trackedPacketFree(&owned); throw error }
        }
        // A missing timestamp differs numerically from a valid one but is NOT evidence of
        // healthy composition offsets. Preserve ownership and use the same refusal policy.
        if packet.pointee.pts == Int64.min || packet.pointee.dts == Int64.min {
            append(packet, poc: nil); videoCount += 1
            try refuse()
            return true
        }
        let offsets = packet.pointee.pts != packet.pointee.dts
        if offsets {
            // Genuine composition offsets always win. A mixed/unsupported sequence is emitted
            // unchanged; do not let its boundary packet overtake packets already held.
            publishPending()
            confirmed = false
            reason = "composition_offsets_present"
            if readyIndex < ready.count { ready.append(packet); return true }
            return false
        }
        if pending.isEmpty {
            guard idr else {
                if readyIndex < ready.count { ready.append(packet); return true }
                return false
            }
            reader.reset()
        }
        let poc = reader.pictureOrderCount(for: packet)
        let invalid = packet.pointee.dts == Int64.min || poc == nil || !reader.isFramePicture
            || (videoCount == 0 && poc != 0)
            || (packet.pointee.flags & AV_PKT_FLAG_KEY != 0 && (!idr || poc != 0))
        append(packet, poc: poc)
        videoCount += 1
        if invalid { try refuse(); return true }
        try checkBounds()
        return true
    }

    private func append(_ packet: UnsafeMutablePointer<AVPacket>, poc: Int64?) {
        pending.append(Entry(packet: packet, poc: poc))
        bytes += Int(max(0, packet.pointee.size))
    }

    private func checkBounds() throws {
        if bytes >= H264PartialCompositionRepair.maximumHeldBytes
            || pending.count >= H264PartialCompositionRepair.maximumHeldPackets
            || videoCount > H264PartialCompositionRepair.maximumPictures { try refuse() }
    }

    private func finishSequence(nextDTS: Int64) throws {
        let video = pending.filter { $0.packet.pointee.stream_index == streamIndex }
        let pictures = video.map { H264PartialCompositionRepair.Picture(dts: $0.packet.pointee.dts, poc: $0.poc ?? -1) }
        guard let corrected = H264PartialCompositionRepair.presentationTimes(
            pictures, nextDTS: nextDTS, presentationLead: lead, previouslyConfirmed: confirmed
        ) else { try refuse(); return }
        if !confirmed {
            sampleCount = video.count; heldCount = pending.count; heldBytes = bytes
            regressions = zip(pictures, pictures.dropFirst()).filter { $1.poc < $0.poc }.count
            EngineLog.emit("[Demuxer] partial H264 composition offsets confirmed: pictures=\(sampleCount) poc_regressions=\(regressions) presentation_lead=\(lead) decode_offset=0 time_base=\(timeBase.num)/\(timeBase.den)", category: .demux)
        }
        // The policy validates the ENTIRE sequence before mutating any packet. Packet payload,
        // DTS, duration, flags, side data, and every non-video stream remain bit-for-bit intact.
        for (entry, pts) in zip(video, corrected) { entry.packet.pointee.pts = pts }
        repairedCount += video.count
        confirmed = true
        reason = "confirmed_partial_composition_offsets"
        publishPending()
    }

    private func refuse() throws {
        reason = "partial_composition_sequence_unproven"
        if confirmed {
            failed = true
            releasePackets()
            throw RepairError.sequenceNoLongerRepairable
        }
        publishPending()
    }

    private func publishPending() {
        ready.append(contentsOf: pending.map(\.packet))
        pending.removeAll(keepingCapacity: true)
        bytes = 0; videoCount = 0
    }

    func dequeue() -> UnsafeMutablePointer<AVPacket>? {
        guard readyIndex < ready.count else { return nil }
        let packet = ready[readyIndex]; readyIndex += 1
        if readyIndex == ready.count { ready.removeAll(keepingCapacity: true); readyIndex = 0 }
        return packet
    }

    func endOfStream() throws {
        if failed { throw RepairError.sequenceNoLongerRepairable }
        guard !pending.isEmpty else { return }
        guard let last = pending.last(where: { $0.packet.pointee.stream_index == streamIndex }) else {
            publishPending(); return
        }
        let (end, overflow) = last.packet.pointee.dts.addingReportingOverflow(max(1, last.packet.pointee.duration))
        guard !overflow else { try refuse(); return }
        try finishSequence(nextDTS: end)
    }

    func noteSeek() {
        releasePackets(); reader.reset()
        confirmed = false; failed = false
        reason = "composition_offsets_present"
    }

    private func releasePackets() {
        for entry in pending { var owned: UnsafeMutablePointer<AVPacket>? = entry.packet; trackedPacketFree(&owned) }
        for packet in ready.dropFirst(readyIndex) { var owned: UnsafeMutablePointer<AVPacket>? = packet; trackedPacketFree(&owned) }
        pending.removeAll(keepingCapacity: true); ready.removeAll(keepingCapacity: true)
        readyIndex = 0; bytes = 0; videoCount = 0
    }

    var summary: String {
        "reason=\(reason) samples=\(sampleCount) held_packets=\(heldCount) held_bytes=\(heldBytes)"
            + " poc_regressions=\(regressions) presentation_lead=\(lead) decode_offset=0"
            + " repaired=\(repairedCount)"
    }
}
