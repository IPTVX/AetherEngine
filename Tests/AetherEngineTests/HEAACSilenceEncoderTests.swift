import Foundation
import AVFoundation
import AudioToolbox
import Testing
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Production HE silence must preserve source configuration and native final-GOP playback.
@Suite(.serialized, .timeLimit(.minutes(4)))
@MainActor
struct HEAACSilenceEncoderTests {
    /// Genuine Apple-encoded source whose ASC the production padding must preserve.
    private struct AudioFixture: Sendable {
        /// Source M4A with actual HE or HE-v2 packets and configuration.
        let source: URL
        /// Requested Apple profile, verified against the decoded container metadata.
        let format: UInt32
    }

    /// Encodes a deterministic tone source; production code independently encodes the zero-PCM tail.
    nonisolated private static func makeAudio(format: UInt32) throws -> AudioFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("he-padding-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.m4a")
        let settings: [String: Any] = [AVFormatIDKey: format, AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: format == kAudioFormatMPEG4AAC_HE_V2 ? 32_000 : 64_000]
        do {
            let file = try AVAudioFile(forWriting: source, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
            let channels = try #require(buffer.floatChannelData)
            let total = 29 * 44_100
            var offset = 0
            while offset < total {
                let count = min(4096, total - offset)
                buffer.frameLength = AVAudioFrameCount(count)
                for channel in 0..<2 {
                    for index in 0..<count { channels[channel][index] = Float(0.2 * sin(2 * .pi * 440 * Double(offset + index) / 44_100)) }
                }
                try file.write(from: buffer)
                offset += count
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return AudioFixture(source: source, format: format)
    }

    /// Actual HE configuration and genuine compressed packets read from the encoded MP4 container.
    private struct EncodedAudio {
        /// Format owner kept alive until the muxer has copied its codec parameters.
        let demuxer: Demuxer
        /// Track pointer owned by demuxer.
        let stream: UnsafeMutablePointer<AVStream>
        /// Original compressed packets with timestamps and durations intact.
        let packets: [SoftwareStoredPacket]
    }

    /// Extracts genuine compressed audio without changing its profile, sample rate or channel layout.
    nonisolated private static func readAudio(_ url: URL) throws -> EncodedAudio {
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: Data(contentsOf: url)), formatHint: "mp4")
        let stream = try #require(demuxer.stream(at: demuxer.audioStreamIndex))
        var packets: [SoftwareStoredPacket] = []
        while let packet = try demuxer.readPacket() {
            defer { var owned = Optional(packet); trackedPacketFree(&owned) }
            if packet.pointee.stream_index != demuxer.audioStreamIndex { continue }
            packet.pointee.time_base = stream.pointee.time_base
            packets.append(try SoftwareStoredPacket(copying: packet))
        }
        return EncodedAudio(demuxer: demuxer, stream: stream, packets: packets)
    }

    /// Builds finite HLS around genuine retimed audio, using production padding only at its uncovered finite edge.
    nonisolated private static func build(_ audio: AudioFixture, usesExplicitASC: Bool, audioDelay: Double = -3) throws -> [String: Data] {
        let source = try readAudio(audio.source)
        defer { source.demuxer.close(); try? FileManager.default.removeItem(at: audio.source.deletingLastPathComponent()) }
        if usesExplicitASC {
            let explicit: [UInt8] = audio.format == kAudioFormatMPEG4AAC_HE_V2 ? [0xeb, 0x8a, 0x08, 0x00] : [0x2b, 0x92, 0x08, 0x00]
            let parameters = try #require(source.stream.pointee.codecpar)
            av_free(parameters.pointee.extradata)
            let storage = try #require(av_mallocz(explicit.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)))
            parameters.pointee.extradata = storage.assumingMemoryBound(to: UInt8.self)
            parameters.pointee.extradata_size = Int32(explicit.count)
            explicit.withUnsafeBytes { storage.copyMemory(from: $0.baseAddress!, byteCount: explicit.count) }
        }
        let parameters = source.stream.pointee.codecpar.pointee
        let sourceASC = Data(bytes: try #require(parameters.extradata), count: Int(parameters.extradata_size))
        let expected = audio.format == kAudioFormatMPEG4AAC_HE_V2 ? AV_PROFILE_AAC_HE_V2 : AV_PROFILE_AAC_HE
        try #require(parameters.profile == expected, "Source encoder did not produce requested HE profile")
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: LongGOPTransportStreamFixture.data()), formatHint: "mpegts")
        let video = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        let videoBase = video.pointee.time_base
        let audioBase = source.stream.pointee.time_base
        var zero: Double?
        try demuxer.peekPackets(maxPackets: 128) { packet in
            if packet.pointee.stream_index == demuxer.videoStreamIndex {
                zero = Double(packet.pointee.dts) * av_q2d(videoBase)
                return true
            }
            return false
        }
        let origin = try #require(zero)
        var videoPackets: [SoftwareStoredPacket] = []
        var videoEnd = 0.0
        var lastIDR = 0.0
        while let packet = try demuxer.readPacket() {
            defer { var owned = Optional(packet); trackedPacketFree(&owned) }
            if packet.pointee.stream_index != demuxer.videoStreamIndex { continue }
            packet.pointee.time_base = videoBase
            let start = Double(packet.pointee.pts) * av_q2d(videoBase) - origin
            if start >= 29 { continue }
            videoEnd = max(videoEnd, Double(packet.pointee.pts + packet.pointee.duration) * av_q2d(videoBase) - origin)
            if packet.pointee.flags & AV_PKT_FLAG_KEY != 0 { lastIDR = start }
            videoPackets.append(try SoftwareStoredPacket(copying: packet))
        }
        let validSource = source.packets.filter {
            let presented = Double($0.dts) * av_q2d(audioBase) + audioDelay
            return presented >= 0 && presented < videoEnd
        }
        let sourceEnd = try #require(validSource.last)
        let audioEnd = Double(sourceEnd.dts + sourceEnd.duration) * av_q2d(audioBase) + audioDelay
        let audioStart = Double(try #require(validSource.first).dts) * av_q2d(audioBase) + audioDelay
        if audioDelay < 0 { try #require(lastIDR < audioEnd && audioEnd < videoEnd - 1) }
        else { try #require(audioStart > 0 && audioStart < 10) }
        let directory = audio.source.deletingLastPathComponent().appendingPathComponent("hls")
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var files: [String: Data] = [:]
        let muxer = try MP4SegmentMuxer(initialSegmentIndex: 0, sessionDir: directory,
            video: .init(codecpar: UnsafePointer(video.pointee.codecpar), timeBase: videoBase, codecTagOverride: "avc1"),
            audio: .init(codecpar: UnsafePointer(source.stream.pointee.codecpar), timeBase: audioBase),
            onInitCaptured: { files["/init.mp4"] = $0 })
        var queue: [(SoftwareStoredPacket, Bool, Double)] = videoPackets.map { ($0, true, Double($0.dts) * av_q2d(videoBase) - origin) }
        queue += validSource.map { ($0, false, Double($0.dts) * av_q2d(audioBase) + audioDelay) }
        let paddingStart = audioDelay < 0 ? Int64((audioEnd / av_q2d(audioBase)).rounded()) : 0
        let paddingEnd = Int64(((audioDelay < 0 ? videoEnd : audioStart) / av_q2d(audioBase)).rounded())
        let outcome: AudioTailPadding.Outcome
        if audioDelay < 0 {
            outcome = AudioTailPadding.heAACSilencePackets(codecpar: UnsafePointer(source.stream.pointee.codecpar),
                startTicks: paddingStart, endTicks: paddingEnd, timeBase: audioBase)
        } else {
            outcome = AudioTailPadding.heAACLeadingSilencePackets(codecpar: UnsafePointer(source.stream.pointee.codecpar),
                startTicks: paddingStart, endTicks: paddingEnd, timeBase: audioBase)
        }
        guard case .packets(let padding, let encoder) = outcome else {
            if case .unavailable(let reason) = outcome { Issue.record(Comment(rawValue: reason)) }
            throw CocoaError(.coderInvalidValue)
        }
        defer { for packet in padding { var owned = Optional(packet); trackedPacketFree(&owned) } }
        try #require(padding.first?.pointee.dts == paddingStart)
        #expect(Data(bytes: parameters.extradata!, count: Int(parameters.extradata_size)) == sourceASC)
        for index in padding.indices {
            let packet = padding[index]
            if index > 0 { #expect(packet.pointee.dts == padding[index - 1].pointee.dts + padding[index - 1].pointee.duration) }
            queue.append((try SoftwareStoredPacket(copying: packet), false, Double(packet.pointee.dts) * av_q2d(audioBase)))
        }
        print("HEAAC_PRODUCTION encoder=\(encoder) packets=\(padding.count) profile=\(parameters.profile) ASC=\(sourceASC.map { String(format: "%02x", $0) }.joined())")
        queue.sort { $0.2 < $1.2 }
        var currentSegment = 0
        for (record, isVideo, seconds) in queue {
            if isVideo, record.flags & AV_PKT_FLAG_KEY != 0 {
                let next = Int((seconds + 0.001) / 10)
                if next > currentSegment {
                    guard case .completed(let path, _) = muxer.cutFragmentForNextSegment(next) else { throw CocoaError(.fileWriteUnknown) }
                    files["/seg\(currentSegment).m4s"] = try Data(contentsOf: path)
                    currentSegment = next
                }
            }
            let packet = try record.makeAVPacket()
            defer { var owned = Optional(packet); trackedPacketFree(&owned) }
            let base = isVideo ? videoBase : audioBase
            let offset = record.pts - record.dts
            packet.pointee.dts = Int64((seconds / av_q2d(base)).rounded())
            packet.pointee.pts = packet.pointee.dts + offset
            packet.pointee.stream_index = isVideo ? muxer.videoOutputStreamIndex : muxer.audioOutputStreamIndex
            av_packet_rescale_ts(packet, base, isVideo ? muxer.muxerVideoTimeBase : muxer.muxerAudioTimeBase)
            try #require(muxer.writePacket(packet).rc >= 0)
        }
        let final = try #require(muxer.finalize())
        files["/seg\(currentSegment).m4s"] = try Data(contentsOf: final.path)
        let verified = Demuxer()
        defer { verified.close() }
        let initialization = try #require(files["/init.mp4"])
        let firstSegment = try #require(files["/seg0.m4s"])
        try verified.open(reader: DataIOReader(parts: [initialization, firstSegment]), formatHint: "mp4")
        let verifiedStream = try #require(verified.stream(at: verified.audioStreamIndex))
        let verifiedParameters = verifiedStream.pointee.codecpar.pointee
        let verifiedExtra = try #require(verifiedParameters.extradata)
        #expect(Data(bytes: verifiedExtra, count: Int(verifiedParameters.extradata_size)) == sourceASC)
        if audioDelay > 0 {
            // The compressed genuine source packets in the first mixed segment remain byte-identical.
            let expectedSource = validSource.filter { Double($0.dts) * av_q2d(audioBase) + audioDelay < 10 }.map(\.bytes)
            var actualSource: [Data] = []
            while let packet = try verified.readPacket() {
                defer { var owned = Optional(packet); trackedPacketFree(&owned) }
                if packet.pointee.stream_index != verified.audioStreamIndex { continue }
                let seconds = Double(packet.pointee.dts) * av_q2d(verifiedStream.pointee.time_base)
                if seconds >= audioStart - 0.0001 {
                    actualSource.append(Data(bytes: packet.pointee.data!, count: Int(packet.pointee.size)))
                }
            }
            #expect(actualSource == expectedSource)
        }


        var playlist = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:11\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MAP:URI=\"init.mp4\"\n"
        for index in 0...currentSegment {
            playlist += "#EXTINF:\(min(10, videoEnd - Double(index) * 10)),\nseg\(index).m4s\n"
        }
        playlist += "#EXT-X-ENDLIST\n"
        files["/media.m3u8"] = Data(playlist.utf8)
        let firstVideoPTS = Double(try #require(videoPackets.first).pts) * av_q2d(videoBase) - origin
        let lastVideoPTS = videoPackets.map { Double($0.pts) * av_q2d(videoBase) - origin }.max() ?? 0
        print("HEAAC_VIDEO firstPTS=\(firstVideoPTS) lastPTS=\(lastVideoPTS) normalizedFinalFrame=\(lastVideoPTS - firstVideoPTS)")
        files["/proof.json"] = try JSONSerialization.data(withJSONObject: ["finalFrame": lastVideoPTS - firstVideoPTS])
        return files
    }

    /// Requires actual video progress through the tail and a newly decoded near-EOF exact-seek frame.
    @Test(arguments: [kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2], [false, true])
    func productionHEAACSilenceReachesFinalGOPAndExactSeek(format: UInt32, usesExplicitASC: Bool) async throws {
        // Failure modes: no HE encoder; container writer rejects HE; source and silence ASC differ;
        // source is actually LC; native playback stops at original audio end; seek returns stale pixels.
        let job = ProbeTestJob { try Self.build(Self.makeAudio(format: format), usesExplicitASC: usesExplicitASC) }
        let files = try await job.outcome().get()
        let origin = try #require(RangeFilesOrigin())
        defer { origin.stop() }
        for (path, data) in files { origin.serve(path, data, contentType: path.hasSuffix("m3u8") ? "application/vnd.apple.mpegurl" : "video/mp4") }
        let item = AVPlayerItem(url: try #require(URL(string: origin.baseURL + "/media.m3u8")))
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        try #require(try await waitFor { item.status != .unknown })
        try #require(item.status == .readyToPlay)
        let metadataBytes = try #require(files["/proof.json"])
        let metadata = try #require(try JSONSerialization.jsonObject(with: metadataBytes) as? [String: Double])
        let finalFrame = try #require(metadata["finalFrame"])
        let ended = ProbeTestBox(false)
        let observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: nil) { _ in
            ended.update { $0 = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        player.play()
        let reached = try await waitFor(upTo: .seconds(35)) { ended.value || item.status == .failed }
        player.pause()
        var display = CMTime.invalid
        let pixel = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: &display)
        print("HEAAC_NATURAL format=\(format) clock=\(player.currentTime().seconds) display=\(display.seconds) pixel=\(pixel != nil) status=\(item.status.rawValue) reached=\(reached) duration=\(item.duration.seconds) loaded=\(item.loadedTimeRanges)")
        #expect(reached && ended.value && pixel != nil && abs(display.seconds - finalFrame) < 0.025)
        let completion = ProbeTestBox<Bool?>(nil)
        player.seek(to: CMTime(seconds: 28, preferredTimescale: 90000), toleranceBefore: .zero, toleranceAfter: .zero) {
            let succeeded = $0
            completion.update { $0 = succeeded }
        }
        try #require(try await waitFor(upTo: .seconds(6)) { completion.value != nil })
        try #require(completion.value == true)
        player.play()
        try #require(try await waitFor(upTo: .seconds(3)) { player.currentTime().seconds > 28.2 })
        player.pause()
        var soughtDisplay = CMTime.invalid
        let soughtPixel = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: &soughtDisplay)
        print("HEAAC_SEEK format=\(format) clock=\(player.currentTime().seconds) display=\(soughtDisplay.seconds) pixel=\(soughtPixel != nil)")
        #expect(soughtPixel != nil && soughtDisplay.seconds >= 28 && soughtDisplay.seconds < 29)
    }
    /// Owns a minimal AAC parameter block for validation tests; every encoded packet remains caller-owned.
    private func withParameters(
        profile: Int32,
        asc: [UInt8],
        body: (UnsafeMutablePointer<AVCodecParameters>) throws -> Void
    ) throws {
        var owned = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&owned) }
        let parameters = try #require(owned)
        parameters.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        parameters.pointee.codec_id = AV_CODEC_ID_AAC
        parameters.pointee.profile = profile
        parameters.pointee.sample_rate = 44_100
        parameters.pointee.bit_rate = profile == AV_PROFILE_AAC_HE_V2 ? 32_000 : 64_000
        av_channel_layout_default(&parameters.pointee.ch_layout, 2)
        let storage = try #require(av_mallocz(asc.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)))
        parameters.pointee.extradata = storage.assumingMemoryBound(to: UInt8.self)
        parameters.pointee.extradata_size = Int32(asc.count)
        asc.withUnsafeBytes { storage.copyMemory(from: $0.baseAddress!, byteCount: asc.count) }
        try body(parameters)
    }

    /// LC stays outside the new HE path, and ordinary padding retains its original HE rejection.
    @Test
    func ordinaryPaddingAndHEProfileGatesRemainSeparate() throws {
        try withParameters(profile: AV_PROFILE_AAC_LOW, asc: [0x12, 0x10]) { parameters in
            let outcome = AudioTailPadding.heAACSilencePackets(codecpar: UnsafePointer(parameters),
                startTicks: 0, endTicks: 44_100, timeBase: AVRational(num: 1, den: 44_100))
            guard case .unavailable(let reason) = outcome else { Issue.record("HE path accepted AAC-LC"); return }
            #expect(reason.contains("known HE-AAC"))
        }
        try withParameters(profile: AV_PROFILE_AAC_HE, asc: [0x13, 0x90, 0x56, 0xe5, 0xa0]) { parameters in
            let outcome = AudioTailPadding.silencePackets(codecpar: UnsafePointer(parameters),
                startTicks: 0, endTicks: 44_100, timeBase: AVRational(num: 1, den: 44_100))
            guard case .unavailable(let reason) = outcome else { Issue.record("Ordinary padding changed its HE gate"); return }
            #expect(reason.contains("not Low Complexity"))
        }
    }

    /// A malformed output interval and an oversized request fail before allocating an encoder or file.
    @Test
    func rejectsInvalidAndUnboundedSpans() throws {
        try withParameters(profile: AV_PROFILE_AAC_HE, asc: [0x13, 0x90, 0x56, 0xe5, 0xa0]) { parameters in
            for (start, end, expected) in [(Int64(5), Int64(5), "invalid finite"), (0, 181 * 44_100, "180 seconds")] {
                let outcome = AudioTailPadding.heAACSilencePackets(codecpar: UnsafePointer(parameters),
                    startTicks: start, endTicks: end, timeBase: AVRational(num: 1, den: 44_100))
                guard case .unavailable(let reason) = outcome else { Issue.record("Invalid span was encoded"); continue }
                #expect(reason.contains(expected))
            }
        }
    }

    /// Source configuration never changes to whatever a convenient encoder happens to produce.
    @Test
    func rejectsAnIncompatibleSourceASC() throws {
        try withParameters(profile: AV_PROFILE_AAC_HE, asc: [0x13, 0x90, 0x56, 0xe5, 0xa1]) { parameters in
            let outcome = AudioTailPadding.heAACSilencePackets(codecpar: UnsafePointer(parameters),
                startTicks: 0, endTicks: 44_100, timeBase: AVRational(num: 1, den: 44_100))
            guard case .unavailable(let reason) = outcome else { Issue.record("Incompatible ASC was relabeled"); return }
            #expect(reason.contains("unsupported trailing AudioSpecificConfig"))
        }
    }

    /// Unknown syntax and tools cannot be silently equated with the proven 1024-frame AAC-LC core.
    @Test(arguments: [[UInt8(0x13), 0x94, 0x56, 0xe5, 0xa0], [0x13, 0x80, 0x56, 0xe5, 0xa0], [0x13, 0x90]])
    func rejectsUnsupportedASCContracts(asc: [UInt8]) throws {
        try withParameters(profile: AV_PROFILE_AAC_HE, asc: asc) { parameters in
            let outcome = AudioTailPadding.heAACSilencePackets(codecpar: UnsafePointer(parameters),
                startTicks: 0, endTicks: 44_100, timeBase: AVRational(num: 1, den: 44_100))
            guard case .unavailable(let reason) = outcome else { Issue.record("Unsupported ASC contract was accepted"); return }
            #expect(reason.contains("unsupported"))
        }
    }

    /// Leading silence may stop one frame short, but must never overlap or replace the first genuine packet.
    @Test(arguments: [false, true])
    func leadingFillKeepsOnlyWholeFramesBeforeGenuineAudio(usesExplicitASC: Bool) throws {
        let asc: [UInt8] = usesExplicitASC ? [0xeb, 0x8a, 0x08, 0x00] : [0x13, 0x88, 0x56, 0xe5, 0xa5, 0x48, 0x80]
        try withParameters(profile: AV_PROFILE_AAC_HE_V2, asc: asc) { parameters in
            let end: Int64 = 3 * 44_100
            let outcome = AudioTailPadding.heAACLeadingSilencePackets(codecpar: UnsafePointer(parameters),
                startTicks: 0, endTicks: end, timeBase: AVRational(num: 1, den: 44_100))
            guard case .packets(let packets, _) = outcome else { Issue.record("Compatible HE leading fill unavailable"); return }
            defer { for packet in packets { var owned = Optional(packet); trackedPacketFree(&owned) } }
            try #require(!packets.isEmpty)
            #expect(packets.first?.pointee.dts == 0)
            let final = try #require(packets.last)
            #expect(final.pointee.dts + final.pointee.duration <= end)
            #expect(end - final.pointee.dts - final.pointee.duration < final.pointee.duration)
        }
    }

    /// Stale generations stop before encoding, or at the next PCM block, without returning owned packets.
    @Test(arguments: [false, true])
    func cancellationReturnsUnavailableWithoutPublishingPackets(cancelDuringEncoding: Bool) throws {
        try withParameters(profile: AV_PROFILE_AAC_HE, asc: [0x13, 0x90, 0x56, 0xe5, 0xa0]) { parameters in
            var checks = 0
            let outcome = AudioTailPadding.heAACSilencePackets(codecpar: UnsafePointer(parameters),
                startTicks: 0, endTicks: 180 * 44_100, timeBase: AVRational(num: 1, den: 44_100), isCurrent: {
                    checks += 1
                    return cancelDuringEncoding && checks < 4
                })
            guard case .unavailable(let reason) = outcome else { Issue.record("Cancelled generation published packets"); return }
            #expect(reason.contains("audio-delay buffering cancelled"))
        }
    }

    /// One finite leading-gap contract, independent of tuple expansion in parameterized test discovery.
    struct LeadingScenario: Sendable {
        /// Apple's genuine HE or HE-v2 output format identifier.
        let format: UInt32
        /// Positive manual delay inside the first mixed segment.
        let delay: Double
        /// Whether the delivered source uses explicit AOT5/29 rather than sync-extension signaling.
        let usesExplicitASC: Bool
    }

    /// Native video starts at zero, seeks within genuine leading silence and continues through the retained source audio.
    @Test(arguments: [
        LeadingScenario(format: kAudioFormatMPEG4AAC_HE, delay: 2.5, usesExplicitASC: false),
        LeadingScenario(format: kAudioFormatMPEG4AAC_HE, delay: 3, usesExplicitASC: true),
        LeadingScenario(format: kAudioFormatMPEG4AAC_HE_V2, delay: 2.5, usesExplicitASC: true),
        LeadingScenario(format: kAudioFormatMPEG4AAC_HE_V2, delay: 3, usesExplicitASC: false),
    ])
    func productionLeadingHEAACPreservesPrefixSeekAndGenuineAudio(
        scenario: LeadingScenario
    ) async throws {
        let job = ProbeTestJob {
            try Self.build(Self.makeAudio(format: scenario.format), usesExplicitASC: scenario.usesExplicitASC, audioDelay: scenario.delay)
        }
        let files = try await job.outcome().get()
        let origin = try #require(RangeFilesOrigin())
        defer { origin.stop() }
        for (path, data) in files { origin.serve(path, data, contentType: path.hasSuffix("m3u8") ? "application/vnd.apple.mpegurl" : "video/mp4") }
        let item = AVPlayerItem(url: try #require(URL(string: origin.baseURL + "/media.m3u8")))
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        try #require(try await waitFor { item.status != .unknown })
        try #require(item.status == .readyToPlay)
        player.play()
        try #require(try await waitFor(upTo: .seconds(4)) { player.currentTime().seconds > 0.2 || item.status == .failed })
        player.pause()
        var firstDisplay = CMTime.invalid
        let firstPixel = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: &firstDisplay)
        print("HEAAC_LEADING_START scenario=\(scenario) clock=\(player.currentTime().seconds) display=\(firstDisplay.seconds) pixel=\(firstPixel != nil)")
        try #require(player.currentTime().seconds < 1 && firstPixel != nil && firstDisplay.seconds < 1)
        let completion = ProbeTestBox<Bool?>(nil)
        player.seek(to: CMTime(seconds: 1, preferredTimescale: 90000), toleranceBefore: .zero, toleranceAfter: .zero) {
            let succeeded = $0
            completion.update { $0 = succeeded }
        }
        try #require(try await waitFor(upTo: .seconds(5)) { completion.value != nil })
        try #require(completion.value == true)
        #expect(abs(player.currentTime().seconds - 1) < 0.05)
        player.play()
        try #require(try await waitFor(upTo: .seconds(3)) { player.currentTime().seconds > 1.2 })
        player.pause()
        var soughtDisplay = CMTime.invalid
        let soughtPixel = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: &soughtDisplay)
        print("HEAAC_LEADING_SEEK scenario=\(scenario) clock=\(player.currentTime().seconds) display=\(soughtDisplay.seconds) pixel=\(soughtPixel != nil)")
        try #require(player.currentTime().seconds < 1.6 && soughtPixel != nil && soughtDisplay.seconds >= 1 && soughtDisplay.seconds < 1.6)
        player.play()
        try #require(try await waitFor(upTo: .seconds(5)) { player.currentTime().seconds > scenario.delay + 0.5 })
        player.pause()
        var genuineDisplay = CMTime.invalid
        let genuinePixel = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: &genuineDisplay)
        print("HEAAC_LEADING_GENUINE scenario=\(scenario) clock=\(player.currentTime().seconds) display=\(genuineDisplay.seconds) pixel=\(genuinePixel != nil)")
        #expect(genuinePixel != nil && genuineDisplay.seconds > scenario.delay + 0.3)
    }

}
