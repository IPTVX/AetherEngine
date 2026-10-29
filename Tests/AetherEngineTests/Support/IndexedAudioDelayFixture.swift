import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// Remuxes the deterministic compressed fixture into an indexed MP4, without external tools or
/// encoding. Real keyframe entries keep public finite seeks independent of the TS uniform plan.
enum IndexedAudioDelayFixture {
    /// Writes one short title or repeated source intervals long enough for both +/-180 s overlaps.
    @discardableResult
    static func write(to url: URL, repetitions: Int = 1, inputURL: URL? = nil) throws -> Double {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        if let inputURL { try demuxer.open(url: inputURL) }
        else { try demuxer.open(reader: DataIOReader(data: LongGOPTransportStreamFixture.data()), formatHint: "mpegts") }
        var context: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&context, nil, "mp4", url.path) >= 0, let context else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { avio_closep(&context.pointee.pb); avformat_free_context(context) }
        var bases: [Int32: AVRational] = [:]
        for index in [demuxer.videoStreamIndex, demuxer.audioStreamIndex] {
            guard let input = demuxer.stream(at: index), let output = avformat_new_stream(context, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            if index == demuxer.audioStreamIndex { _ = HLSVideoEngine.prepareAACForFMP4(input.pointee.codecpar) }
            guard avcodec_parameters_copy(output.pointee.codecpar, input.pointee.codecpar) >= 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            output.pointee.time_base = input.pointee.time_base
            output.pointee.codecpar.pointee.codec_tag = 0
            bases[index] = input.pointee.time_base
        }
        guard avio_open(&context.pointee.pb, url.path, AVIO_FLAG_WRITE) >= 0,
              avformat_write_header(context, nil) >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var packets: [SoftwareStoredPacket] = []
        var zero: Double?
        while let packet = try demuxer.readPacket() {
            defer { av_packet_unref(packet); av_packet_free_safe(packet) }
            guard let base = bases[packet.pointee.stream_index] else { continue }
            if packet.pointee.stream_index == demuxer.videoStreamIndex, zero == nil {
                zero = Double(packet.pointee.dts) * av_q2d(base)
            }
            if packet.pointee.stream_index == demuxer.audioStreamIndex,
               let bytes = packet.pointee.data, packet.pointee.size >= 7,
               bytes[0] == 0xff, bytes[1] & 0xf0 == 0xf0 {
                let size = bytes[1] & 1 == 0 ? 9 : 7
                if packet.pointee.size >= size {
                    memmove(bytes, bytes + size, Int(packet.pointee.size) - size)
                    av_shrink_packet(packet, packet.pointee.size - Int32(size))
                }
            }
            packets.append(try .init(copying: packet))
        }
        guard let zero else { throw CocoaError(.fileReadCorruptFile) }
        let sourceEnd = packets.compactMap { record -> Double? in
            guard let base = bases[record.streamIndex], record.pts != Int64.min else { return nil }
            return Double(record.pts + max(record.duration, 0)) * av_q2d(base) - zero
        }.max() ?? demuxer.duration
        let videoEnd = packets.filter { $0.streamIndex == demuxer.videoStreamIndex }.compactMap { record -> Double? in
            guard let base = bases[record.streamIndex], record.pts != Int64.min else { return nil }
            return Double(record.pts + max(record.duration, 0)) * av_q2d(base) - zero
        }.max() ?? sourceEnd
        let stride = sourceEnd + 0.001
        for repetition in 0..<repetitions {
            for record in packets {
                let packet = try record.makeAVPacket()
                defer { av_packet_unref(packet); av_packet_free_safe(packet) }
                guard let base = bases[record.streamIndex] else { continue }
                let shift = Int64((Double(repetition) * stride / av_q2d(base) - zero / av_q2d(base)).rounded())
                if packet.pointee.pts != Int64.min { packet.pointee.pts += shift }
                if packet.pointee.dts != Int64.min { packet.pointee.dts += shift }
                if packet.pointee.dts < 0 { continue }
                let index: Int32 = record.streamIndex == demuxer.videoStreamIndex ? 0 : 1
                packet.pointee.stream_index = index
                let output = context.pointee.streams[Int(index)]!
                av_packet_rescale_ts(packet, base, output.pointee.time_base)
                guard av_interleaved_write_frame(context, packet) >= 0 else { throw CocoaError(.fileWriteUnknown) }
            }
        }
        guard av_write_trailer(context) >= 0 else { throw CocoaError(.fileWriteUnknown) }
        return Double(repetitions - 1) * stride + videoEnd
    }
}
