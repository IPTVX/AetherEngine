import Foundation
import AetherLibavcodec
import AetherLibavutil

/// Performs source-order effects before compressed cross-track scheduling. The decoder consumes
/// the resulting original timestamps; the offset changes ordering only, never packet contents.
final class SoftwareAudioDelayPacketSource {
    /// Normalized packet sequence epoch, advanced only at genuine source discontinuities.
    private(set) var epoch: UInt64 = 0
    /// First video timestamp before alignment; Live warmup is measured from this origin.
    private(set) var firstVideoSeconds: Double?
    /// Each stream owns its fold until it catches the other side of the same transport seam.
    private var timelineFold = LiveTimelineFold()
    /// Resolved stream identities and time bases, independent of AVPacket.time_base omissions.
    private let video: Int32
    private let audio: Int32
    private let timeBase: (Int32) -> AVRational
    /// The sole reader and its generation admission check.
    private let readSource: () throws -> UnsafeMutablePointer<AVPacket>?
    private let isCurrent: () -> Bool
    /// Source-order recording stays before normalization, exactly once per original packet.
    private let recordingTap: (UnsafeMutablePointer<AVPacket>) -> Void
    /// Source-axis telemetry runs after folding but before queues change track order.
    private let prepared: (UnsafeMutablePointer<AVPacket>, Double) -> Void
    /// A DVR reader has already performed source-order normalization and recording.
    private let foldsTimeline: Bool

    /// Binds one reader epoch; ownership of each input pointer ends inside read().
    init(video: Int32, audio: Int32, foldsTimeline: Bool,
         timeBase: @escaping (Int32) -> AVRational,
         readSource: @escaping () throws -> UnsafeMutablePointer<AVPacket>?,
         isCurrent: @escaping () -> Bool,
         recordingTap: @escaping (UnsafeMutablePointer<AVPacket>) -> Void,
         prepared: @escaping (UnsafeMutablePointer<AVPacket>, Double) -> Void) {
        self.video = video; self.audio = audio; self.foldsTimeline = foldsTimeline
        self.timeBase = timeBase; self.readSource = readSource; self.isCurrent = isCurrent
        self.recordingTap = recordingTap; self.prepared = prepared
    }

    /// Reads, admits, records and folds a packet before transferring its lossless envelope.
    func read() throws -> CompressedAudioDelayAlignment.Packet? {
        if !isCurrent() { throw CancellationError() }
        guard let packet = try readSource() else { return nil }
        defer { av_packet_unref(packet); av_packet_free_safe(packet) }
        if !isCurrent() { throw CancellationError() }
        recordingTap(packet)
        let stream = packet.pointee.stream_index
        let tb = timeBase(stream)
        let secondsPerTick = tb.den > 0 ? Double(tb.num) / Double(tb.den) : 0
        if foldsTimeline, secondsPerTick > 0 {
            let foldStream: LiveTimelineFold.Stream = stream == audio ? .audio : .video
            if (stream == video || stream == audio), packet.pointee.pts != Int64.min,
               let seam = timelineFold.observe(foldStream, rawSeconds: Double(packet.pointee.pts) * secondsPerTick),
               !seam.adopted {
                epoch &+= 1
            }
            let offset = timelineFold.offsetSeconds(for: foldStream)
            if offset != 0 {
                let ticks = SourceTimestampBounds.roundedTicks(offset / secondsPerTick)
                packet.pointee.pts = SourceTimestampBounds.shifted(packet.pointee.pts, back: ticks)
                packet.pointee.dts = SourceTimestampBounds.shifted(packet.pointee.dts, back: ticks)
            }
        }
        let pts = packet.pointee.pts != Int64.min ? Double(packet.pointee.pts) * secondsPerTick : .nan
        if stream == video, firstVideoSeconds == nil, pts.isFinite { firstVideoSeconds = pts }
        prepared(packet, pts)
        packet.pointee.time_base = tb
        return .init(record: try SoftwareStoredPacket(copying: packet),
                     lane: stream == video ? .video : (stream == audio ? .audio : .other), epoch: epoch)
    }
}
