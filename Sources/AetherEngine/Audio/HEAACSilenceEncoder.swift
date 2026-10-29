import Foundation
import AVFAudio
import AudioToolbox
import AetherLibavcodec
import AetherLibavutil

/// Encodes a bounded zero-PCM HE-AAC tail without changing the source's compressed configuration.
/// Only the separately authorized finite-alignment path calls this helper; ordinary padding stays unchanged.
enum HEAACSilenceEncoder {
    /// Maximum requested finite delay; the extra second below is encoder priming, never source audio.
    private static let maximumSpanSeconds = 180.0
    /// Caps the temporary container and returned compressed payload independently of encoder behavior.
    private static let maximumEncodedBytes = 8 * 1024 * 1024
    /// Bounds packet allocations even if a malformed encoder output advertises tiny durations.
    private static let maximumPacketCount = 20_000

    /// Actionable failures stay inside the existing padding outcome instead of escaping from a producer thread.
    private enum EncodingError: Error, CustomStringConvertible {
        /// The source or an Apple encoder result cannot preserve the requested format or bounded lifetime.
        case unavailable(String)

        /// Context included in the producer's existing unavailable-padding diagnostics.
        var description: String {
            switch self {
            case .unavailable(let reason): return "HE-AAC silence: \(reason)"
            }
        }
    }

    /// Returns owned raw AAC packets in the caller's time base, or a concrete reason same-format encoding is unavailable.
    /// The source ASC stays unchanged; equivalent explicit and sync-extension SBR/PS forms must describe identical audio.
    /// `isCurrent` is invoked synchronously on the caller thread and must be safe for that producer context.
    static func packets(
        codecpar: UnsafePointer<AVCodecParameters>,
        startTicks: Int64,
        endTicks: Int64,
        timeBase: AVRational,
        isCurrent: (() -> Bool)? = nil
    ) -> AudioTailPadding.Outcome {
        var packets: [UnsafeMutablePointer<AVPacket>] = []
        do {
            try checkCurrent(isCurrent)
            let source = codecpar.pointee
            guard source.codec_id == AV_CODEC_ID_AAC,
                  source.profile == AV_PROFILE_AAC_HE || source.profile == AV_PROFILE_AAC_HE_V2 else {
                throw EncodingError.unavailable("requires a known HE-AAC or HE-AAC-v2 source profile (got \(source.profile))")
            }
            guard timeBase.num > 0, timeBase.den > 0, startTicks >= 0, endTicks > startTicks else {
                throw EncodingError.unavailable("invalid finite output span \(startTicks)...\(endTicks) at \(timeBase.num)/\(timeBase.den)")
            }
            let span = Double(endTicks - startTicks) * av_q2d(timeBase)
            guard span.isFinite, span <= maximumSpanSeconds,
                  source.sample_rate > 0, source.sample_rate <= 96_000,
                  source.ch_layout.nb_channels > 0, source.ch_layout.nb_channels <= 2,
                  source.extradata_size > 0, source.extradata_size <= 64,
                  let extra = source.extradata else {
                throw EncodingError.unavailable("requires at most 180 seconds, a valid ASC, and a supported mono/stereo output rate (span \(span), rate \(source.sample_rate), channels \(source.ch_layout.nb_channels))")
            }
            let expectedASC = Data(bytes: extra, count: Int(source.extradata_size))
            let expectedConfiguration = try configuration(expectedASC)
            guard expectedConfiguration.outputRate == source.sample_rate,
                  expectedConfiguration.outputChannels == source.ch_layout.nb_channels,
                  expectedConfiguration.parametricStereo == (source.profile == AV_PROFILE_AAC_HE_V2),
                  source.frame_size == 0 || source.frame_size == 2048 else {
                throw EncodingError.unavailable("source ASC contradicts its HE profile, output rate, channels or frame length")
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aether-he-tail-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("silence.m4a")
            // One second covers Apple's reported priming while keeping PCM storage at one 4096-frame block.
            try writeSilence(to: file, source: source, duration: span + 1, isCurrent: isCurrent)
            try checkCurrent(isCurrent)
            let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
            guard let size, size.intValue <= maximumEncodedBytes else {
                throw EncodingError.unavailable("temporary encoded tail exceeds the 8 MiB bound")
            }
            let priming = try primingFrames(in: file)
            let demuxer = Demuxer()
            defer { demuxer.close() }
            try demuxer.open(url: file)
            guard let stream = demuxer.stream(at: demuxer.audioStreamIndex) else {
                throw EncodingError.unavailable("Apple's encoded file contains no audio stream")
            }
            let actual = stream.pointee.codecpar.pointee
            guard actual.codec_id == AV_CODEC_ID_AAC, actual.profile == source.profile,
                  actual.sample_rate == source.sample_rate,
                  actual.ch_layout.nb_channels == source.ch_layout.nb_channels,
                  actual.extradata_size > 0, actual.extradata_size <= 64,
                  let actualExtra = actual.extradata else {
                throw EncodingError.unavailable("Apple encoder configuration differs from source ASC/profile/rate/channels; source profile \(source.profile), rate \(source.sample_rate), channels \(source.ch_layout.nb_channels); encoded profile \(actual.profile), rate \(actual.sample_rate), channels \(actual.ch_layout.nb_channels)")
            }
            let actualConfiguration = try configuration(Data(bytes: actualExtra, count: Int(actual.extradata_size)))
            guard actualConfiguration == expectedConfiguration else {
                throw EncodingError.unavailable("Apple encoder differs from source ASC core/output rates, channels, PS or frame length")
            }
            let coreBase = stream.pointee.time_base
            guard coreBase.num > 0, coreBase.den > 0 else {
                throw EncodingError.unavailable("encoded AAC core clock is invalid")
            }
            // Packet-table priming is measured in the container's core clock: 2112/22050 for
            // 44100 Hz HE, not 2112/44100. Keep enough genuine zero PCM after that decoder delay.
            let primingSeconds = Double(priming) / Double(actualConfiguration.coreRate)
            guard primingSeconds >= 0, primingSeconds <= 1 else {
                throw EncodingError.unavailable("encoder priming \(primingSeconds)s exceeds the reserved one-second bound")
            }
            let requiredSeconds = span + primingSeconds
            var consumed: Int64 = 0
            var payloadBytes = 0
            while true {
                try checkCurrent(isCurrent)
                guard let packet = try demuxer.readPacket() else { break }
                var owned = Optional(packet)
                defer { trackedPacketFree(&owned) }
                if packet.pointee.stream_index != demuxer.audioStreamIndex { continue }
                if Double(consumed) * av_q2d(coreBase) >= requiredSeconds { break }
                let duration = packet.pointee.duration
                guard duration > 0, consumed <= Int64.max - duration,
                      packets.count < maximumPacketCount, packet.pointee.size > 0,
                      Int(packet.pointee.size) <= maximumEncodedBytes - payloadBytes else {
                    throw EncodingError.unavailable("encoded packet duration, count or payload exceeded its finite bound")
                }
                let relativeStart = av_rescale_q(consumed, coreBase, timeBase)
                let relativeEnd = av_rescale_q(consumed + duration, coreBase, timeBase)
                guard relativeEnd > relativeStart, startTicks <= Int64.max - relativeEnd else {
                    throw EncodingError.unavailable("output time base cannot represent contiguous HE frames")
                }
                packet.pointee.dts = startTicks + relativeStart
                packet.pointee.pts = packet.pointee.dts
                packet.pointee.duration = relativeEnd - relativeStart
                packet.pointee.time_base = timeBase
                consumed += duration
                payloadBytes += Int(packet.pointee.size)
                packets.append(packet)
                owned = nil
            }
            guard !packets.isEmpty, Double(consumed) * av_q2d(coreBase) >= requiredSeconds else {
                throw EncodingError.unavailable("encoder produced insufficient zero PCM to cover the requested tail and priming")
            }
            try checkCurrent(isCurrent)
            return .packets(packets, encoder: source.profile == AV_PROFILE_AAC_HE_V2 ? "Apple HE-AAC-v2" : "Apple HE-AAC")
        } catch {
            for packet in packets {
                var owned = Optional(packet)
                trackedPacketFree(&owned)
            }
            return .unavailable(String(describing: error))
        }
    }

    /// The supported HE contract, independent of explicit AOT5/29 versus backward-compatible sync signaling.
    private struct Configuration: Equatable {
        /// AAC-LC core sample clock; packet-table priming uses this rate.
        let coreRate: Int32
        /// Decoded sample clock after SBR.
        let outputRate: Int32
        /// Mono or stereo AAC core channel configuration, never a PCE or downmix.
        let coreChannels: Int32
        /// Rendered channel count after optional parametric stereo.
        let outputChannels: Int32
        /// Whether the mono core expands through PS, rather than an ordinary stereo core.
        let parametricStereo: Bool
        /// GASpecificConfig's frame-length flag, explicitly checked rather than inferred from profile.
        let shortFrame: Bool
    }

    /// Checked ASC bit reads; unknown or truncated signaling fails instead of assuming AAC-LC defaults.
    private struct Bits {
        /// Small, bounded configuration copied from the source ASC.
        let bytes: [UInt8]
        /// Next unread bit, most significant bit first.
        var offset = 0
        /// Bits not consumed by the supported syntax.
        var remaining: Int { bytes.count * 8 - offset }

        /// Reads a fixed field or reports a truncated ASC.
        mutating func read(_ count: Int) throws -> Int {
            guard count <= remaining else { throw EncodingError.unavailable("unsupported truncated AudioSpecificConfig") }
            var value = 0
            for _ in 0..<count {
                value = (value << 1) | Int((bytes[offset / 8] >> (7 - offset % 8)) & 1)
                offset += 1
            }
            return value
        }

        /// Resolves table or explicit frequency signaling without guessing reserved indexes.
        mutating func frequency() throws -> Int32 {
            let index = try read(4)
            if index == 15 {
                let value = try read(24)
                guard value > 0, value <= 96_000 else { throw EncodingError.unavailable("unsupported explicit AAC frequency") }
                return Int32(value)
            }
            let values: [Int32] = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
            guard index < values.count else { throw EncodingError.unavailable("unsupported reserved AAC frequency index") }
            return values[index]
        }
    }

    /// Parses only proven AAC-LC+SBR/PS forms; PCE, scalable tools, 960-frame and unknown extensions are unsupported.
    /// Field order follows FFmpeg's MPEG4AudioConfig parser and AAC GASpecificConfig, without scanning for magic bits.
    private static func configuration(_ asc: Data) throws -> Configuration {
        var bits = Bits(bytes: Array(asc))
        let objectType = try bits.read(5)
        let coreRate = try bits.frequency()
        let channels = try bits.read(4)
        guard channels == 1 || channels == 2 else { throw EncodingError.unavailable("unsupported AAC PCE or multichannel configuration") }
        var outputRate = coreRate
        var ps = objectType == 29
        let explicit = objectType == 5 || objectType == 29
        if explicit {
            outputRate = try bits.frequency()
            guard try bits.read(5) == 2 else { throw EncodingError.unavailable("unsupported HE core object type; requires AAC-LC") }
        } else if objectType != 2 {
            throw EncodingError.unavailable("unsupported AudioSpecificConfig object type \(objectType)")
        }
        let shortFrame = try bits.read(1) != 0
        let dependsOnCoreCoder = try bits.read(1) != 0
        let extensionFlag = try bits.read(1) != 0
        guard !shortFrame, !dependsOnCoreCoder, !extensionFlag else {
            throw EncodingError.unavailable("unsupported AAC frame-length, core-coder or scalable extension flags")
        }
        if !explicit {
            guard try bits.read(11) == 0x2b7, try bits.read(5) == 5, try bits.read(1) == 1 else {
                throw EncodingError.unavailable("unsupported implicit HE ASC; requires an explicit SBR sync extension")
            }
            outputRate = try bits.frequency()
            if bits.remaining >= 12 {
                guard try bits.read(11) == 0x548 else { throw EncodingError.unavailable("unsupported AAC sync extension") }
                ps = try bits.read(1) != 0
            }
        }
        guard bits.remaining <= 7, try bits.read(bits.remaining) == 0 else {
            throw EncodingError.unavailable("unsupported trailing AudioSpecificConfig extension")
        }
        guard outputRate == coreRate * 2, !ps || channels == 1 else {
            throw EncodingError.unavailable("unsupported HE SBR ratio or PS channel configuration")
        }
        return Configuration(coreRate: coreRate, outputRate: outputRate, coreChannels: Int32(channels),
            outputChannels: ps ? 2 : Int32(channels), parametricStereo: ps, shortFrame: shortFrame)
    }

    /// Writes only zero PCM through Apple's requested HE encoder, with fixed input memory and a bounded file.
    private static func writeSilence(
        to url: URL,
        source: AVCodecParameters,
        duration: Double,
        isCurrent: (() -> Bool)?
    ) throws {
        let profile = source.profile == AV_PROFILE_AAC_HE_V2 ? kAudioFormatMPEG4AAC_HE_V2 : kAudioFormatMPEG4AAC_HE
        let bitRate = source.bit_rate > 0 ? Int(source.bit_rate) : (source.profile == AV_PROFILE_AAC_HE_V2 ? 32_000 : 64_000)
        guard bitRate <= 256_000 else { throw EncodingError.unavailable("source bitrate \(bitRate) exceeds bounded HE encoding") }
        let settings: [String: Any] = [AVFormatIDKey: profile, AVSampleRateKey: source.sample_rate,
            AVNumberOfChannelsKey: source.ch_layout.nb_channels, AVEncoderBitRateKey: bitRate]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096),
              let channels = buffer.floatChannelData else { throw EncodingError.unavailable("PCM input buffer allocation failed") }
        for channel in 0..<Int(source.ch_layout.nb_channels) { channels[channel].initialize(repeating: 0, count: 4096) }
        let total = Int((duration * Double(source.sample_rate)).rounded(.up))
        var written = 0
        var nextSizeCheck = Int(source.sample_rate)
        while written < total {
            try checkCurrent(isCurrent)
            let frames = min(4096, total - written)
            buffer.frameLength = AVAudioFrameCount(frames)
            try file.write(from: buffer)
            written += frames
            if written >= nextSizeCheck {
                let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
                if let size, size.intValue > maximumEncodedBytes { throw EncodingError.unavailable("temporary encoded tail exceeds the 8 MiB bound") }
                nextSizeCheck += Int(source.sample_rate)
            }
        }
    }

    /// Cooperatively releases all scratch resources when the owning finite-alignment generation ends.
    private static func checkCurrent(_ isCurrent: (() -> Bool)?) throws {
        if let isCurrent, !isCurrent() { throw EncodingError.unavailable("audio-delay buffering cancelled") }
    }

    /// Reads the actual encoder's priming count after the temporary M4A writer has closed.
    private static func primingFrames(in url: URL) throws -> Int32 {
        var file: AudioFileID?
        let opened = AudioFileOpenURL(url as CFURL, .readPermission, 0, &file)
        guard opened == noErr, let file else { throw EncodingError.unavailable("cannot open encoded packet table (OSStatus \(opened))") }
        defer { AudioFileClose(file) }
        var table = AudioFilePacketTableInfo()
        var size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
        let status = AudioFileGetProperty(file, kAudioFilePropertyPacketTableInfo, &size, &table)
        guard status == noErr, table.mPrimingFrames >= 0 else { throw EncodingError.unavailable("invalid encoder packet table (OSStatus \(status))") }
        return table.mPrimingFrames
    }
}
