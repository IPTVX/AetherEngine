import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// Extends the existing synthetic closed-GOP fixture without an external encoder or network.
enum LongAudioDelayTransportStreamFixture {
    /// Writes eight monotonically timestamped repetitions (about 257 seconds) to a unique test-owned path.
    static func write(to url: URL) throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: LongGOPTransportStreamFixture.data()), formatHint: "mpegts")
        var context: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&context, nil, "mpegts", url.path) >= 0, let context else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { avio_closep(&context.pointee.pb); avformat_free_context(context) }
        var bases: [Int32: AVRational] = [:]
        for index in [demuxer.videoStreamIndex, demuxer.audioStreamIndex] {
            guard let input = demuxer.stream(at: index), let output = avformat_new_stream(context, nil),
                  avcodec_parameters_copy(output.pointee.codecpar, input.pointee.codecpar) >= 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            output.pointee.time_base = input.pointee.time_base
            output.pointee.codecpar.pointee.codec_tag = 0
            bases[index] = input.pointee.time_base
        }
        guard avio_open(&context.pointee.pb, url.path, AVIO_FLAG_WRITE) >= 0,
              avformat_write_header(context, nil) >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var packets: [SoftwareStoredPacket] = []
        while let packet = try demuxer.readPacket() {
            defer { av_packet_unref(packet); av_packet_free_safe(packet) }
            if bases[packet.pointee.stream_index] != nil { packets.append(try .init(copying: packet)) }
        }
        for repetition in 0..<8 {
            for record in packets {
                let packet = try record.makeAVPacket()
                defer { av_packet_unref(packet); av_packet_free_safe(packet) }
                guard let base = bases[record.streamIndex] else { continue }
                let shift = Int64((Double(repetition) * 32.1 / av_q2d(base)).rounded())
                if packet.pointee.pts != Int64.min { packet.pointee.pts += shift }
                if packet.pointee.dts != Int64.min { packet.pointee.dts += shift }
                let outputIndex: Int32 = record.streamIndex == demuxer.videoStreamIndex ? 0 : 1
                packet.pointee.stream_index = outputIndex
                let output = context.pointee.streams[Int(outputIndex)]!
                av_packet_rescale_ts(packet, base, output.pointee.time_base)
                guard av_interleaved_write_frame(context, packet) >= 0 else { throw CocoaError(.fileWriteUnknown) }
            }
        }
        guard av_write_trailer(context) >= 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
