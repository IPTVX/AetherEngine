import Foundation

/// Compressed VOD packet prefetch, independent of renderer pacing. The producer owns source reads;
/// the consumer gets byte-identical packet envelopes from a bounded disk FIFO. No main-thread I/O.
/// Cached seeks move only the consumer cursor. A source reposition has a separate epoch, so an
/// in-flight producer packet is neither lost nor duplicated when replaying retained data.
final class SoftwarePacketReadAhead: @unchecked Sendable {
    struct Stream: Sendable {
        let index: Int32
        let numerator: Int32
        let denominator: Int32
    }
    struct Snapshot: Sendable {
        let packetCount: Int
        let bytes: Int
        let residentBytes: Int
        let frontier: Double?
        let generation: UInt64
        let seeking: Bool
        let sourceEnded: Bool
        let sourceEpoch: UInt64
        let cacheSeekHits: UInt64
        let cacheSeekMisses: UInt64
    }
    enum ReadError: Error { case interrupted, closed, corruptFIFO }

    private let condition = NSCondition()
    /// Never acquired by a main-thread API. Serializes reset with append/pop, including the
    /// generation check, so an old consumer cannot pop and discard the first NEW-generation packet.
    private let operations = NSLock()
    private let fifo: SoftwarePacketDiskFIFO
    private let readSource: @Sendable (@Sendable () -> Bool) throws -> SoftwareStoredPacket?
    private let beforeConsumerOperation: (@Sendable () -> Void)?
    private let video: Stream
    private let audio: Stream?
    private let byteBudget: Int
    private let forwardSeconds: Double
    private let worker = DispatchQueue(label: "engine.sw.packet-prefetch", qos: .utility)
    private var generation: UInt64 = 0
    private var sourceEpoch: UInt64 = 0
    private var sourceRepositioning = false
    private var cacheSeekHits: UInt64 = 0
    private var cacheSeekMisses: UInt64 = 0
    private var resetPending = false
    private var seeking = false
    private var closed = false
    private var started = false
    private var ended = false
    private var failure: Error?
    private var count = 0
    private var bytes = 0
    private var residentBytes = 0
    private var sourceClock: Double
    private var videoCoverage = SoftwarePacketCoverage()
    private var audioCoverage = SoftwarePacketCoverage()
    private var presentationCoverage: SoftwareVideoPacketCoverage?
    private struct Keyframe {
        let seconds: Double
        let cursor: SoftwarePacketDiskFIFO.Cursor
    }
    private var keyframes: [Keyframe] = []
    private let maximumKeyframes = 65_536

    /// Construct only off-main: creating the FIFO touches the temporary volume.
    init(video: Stream, audio: Stream?, byteBudget: Int, forwardSeconds: Double,
         initialSourceClock: Double, fifo: SoftwarePacketDiskFIFO,
         videoReorderDepth: Int? = nil,
         beforeConsumerOperation: (@Sendable () -> Void)? = nil,
         readSource: @escaping @Sendable (@Sendable () -> Bool) throws -> SoftwareStoredPacket?) {
        self.video = video
        self.audio = audio
        self.byteBudget = max(1, byteBudget)
        self.forwardSeconds = max(1, forwardSeconds)
        self.sourceClock = initialSourceClock
        self.fifo = fifo
        self.presentationCoverage = videoReorderDepth.map {
            SoftwareVideoPacketCoverage(timeBaseNumerator: video.numerator,
                timeBaseDenominator: video.denominator, reorderDepth: $0)
        }
        self.beforeConsumerOperation = beforeConsumerOperation
        self.readSource = readSource
    }

    func start() {
        condition.lock()
        guard !started, !closed else { condition.unlock(); return }
        started = true
        condition.unlock()
        worker.async { self.produce() }
    }

    var snapshot: Snapshot {
        condition.lock(); defer { condition.unlock() }
        return Snapshot(packetCount: count, bytes: bytes, residentBytes: residentBytes,
                        frontier: sourceRepositioning || closed ? nil : frontierLocked(),
                        generation: generation, seeking: seeking, sourceEnded: ended,
                        sourceEpoch: sourceEpoch, cacheSeekHits: cacheSeekHits,
                        cacheSeekMisses: cacheSeekMisses)
    }

    /// Main-thread safe: metadata only. Decode/render backpressure still belongs to the old loop.
    func updatePlayhead(_ seconds: Double) {
        guard seconds.isFinite else { return }
        condition.lock()
        sourceClock = seconds
        // Presentation history stays useful for backward cached seeks. Coverage has a fixed range
        // cap; retained keyframe cursors, not a guessed timestamp floor, decide cache eligibility.
        condition.broadcast()
        condition.unlock()
    }

    /// Legacy explicit cold seek. Production first uses beginSeek(to:) + prepareSeek off-main.
    @discardableResult
    func beginSeek() -> UInt64 {
        condition.lock(); defer { condition.unlock() }
        generation &+= 1
        sourceEpoch &+= 1
        sourceRepositioning = true
        seeking = true
        resetPending = true
        clearSourceMetadataLocked()
        condition.broadcast()
        return generation
    }

    /// Main-thread safe: freeze only the decoder/consumer, not the source reader or retained data.
    @discardableResult
    func beginSeek(to seconds: Double) -> UInt64 {
        condition.lock(); defer { condition.unlock() }
        generation &+= 1
        seeking = true
        if seconds.isFinite { sourceClock = seconds }
        condition.broadcast()
        return generation
    }

    /// Off-main, BEFORE any actual demuxer reposition. true means the target is already retained.
    /// A hit does not change sourceEpoch: an in-flight source read must still be stored afterwards.
    func prepareSeek(_ token: UInt64, to seconds: Double) throws -> Bool {
        operations.lock(); defer { operations.unlock() }
        condition.lock()
        guard token == generation, seeking, !closed else {
            condition.unlock(); throw ReadError.interrupted
        }
        let hasCoverage = !sourceRepositioning && !resetPending && failure == nil
            && seconds.isFinite && (frontierLocked(at: seconds).map { $0 > seconds } ?? false)
        let candidates = hasCoverage ? keyframes.filter { $0.seconds <= seconds }
            .sorted { $0.seconds < $1.seconds } : []
        // A previous recovery/key picture supplies open-GOP/audio preroll when still retained.
        let anchor = candidates.isEmpty ? nil : candidates[max(0, candidates.count - 2)]
        condition.unlock()

        if let anchor {
            do {
                try fifo.restore(to: anchor.cursor)
                let state = fifo.snapshot
                condition.lock(); defer { condition.unlock() }
                guard token == generation, !closed else { throw ReadError.interrupted }
                copyDiskStateLocked(state)
                sourceClock = seconds
                cacheSeekHits &+= 1
                condition.broadcast()
                return true
            } catch SoftwarePacketDiskFIFO.Failure.invalidCursor {
                // An expired bookmark is a cache miss, never a playback/disk failure.
            } catch SoftwarePacketDiskFIFO.Failure.retentionDisabled {
                // Keeps callers using the legacy destructive FIFO safe during migration.
            }
        }

        condition.lock()
        guard token == generation, !closed else {
            condition.unlock(); throw ReadError.interrupted
        }
        sourceEpoch &+= 1
        sourceRepositioning = true
        resetPending = false
        clearSourceMetadataLocked()
        sourceClock = seconds
        cacheSeekMisses &+= 1
        condition.broadcast()
        condition.unlock()
        try fifo.reset()
        return false
    }

    func endSeek(_ token: UInt64, sourceClock: Double) {
        condition.lock(); defer { condition.unlock() }
        guard token == generation, !closed else { return }
        self.sourceClock = sourceClock
        seeking = false
        sourceRepositioning = false
        condition.broadcast()
    }

    /// Does not wait for a remote read or a disk operation. The host closes the Demuxer as usual,
    /// unblocking its reader; the worker then releases only its own unique FIFO directory.
    func close() {
        condition.lock()
        guard !closed else { condition.unlock(); return }
        closed = true
        generation &+= 1
        sourceEpoch &+= 1
        clearSourceMetadataLocked()
        let needsCleanup = !started
        condition.broadcast()
        condition.unlock()
        if needsCleanup { worker.async { try? self.fifo.close() } }
    }

    /// Consumer thread only. nil means true EOF; a seek wake is explicitly different from EOF.
    func read(isCurrent: @Sendable () -> Bool = { true }) throws -> SoftwareStoredPacket? {
        condition.lock()
        let token = generation
        while count == 0, !ended, failure == nil, !closed, !seeking,
              token == generation, isCurrent() {
            condition.wait()
        }
        if closed { condition.unlock(); throw ReadError.closed }
        let hadPackets = count > 0
        condition.unlock()

        if hadPackets { beforeConsumerOperation?() }
        operations.lock()
        defer { operations.unlock() }
        condition.lock()
        guard !closed else { condition.unlock(); throw ReadError.closed }
        // Admission belongs to the HOST generation too. Capturing only our generation at read()
        // entry can let an old host iteration steal the first packet of a completed new seek.
        guard !seeking, token == generation, isCurrent() else {
            condition.unlock(); throw ReadError.interrupted
        }
        if count == 0 {
            let error = failure
            condition.unlock()
            if let error { throw error }
            return nil
        }
        condition.unlock()
        guard let data = try fifo.pop() else { throw ReadError.corruptFIFO }
        let packet = try SoftwareStoredPacket.decode(data)
        // Equality parks the producer too. Reclaim an eligible consumed chunk at the exact ceiling,
        // otherwise it can remain asleep with unread packets until the queue drains completely.
        try fifo.trimConsumed(toByteBudget: max(0, byteBudget - 1))
        let state = fifo.snapshot
        condition.lock()
        defer { condition.unlock() }
        guard !closed, !seeking, token == generation, isCurrent() else { throw ReadError.interrupted }
        copyDiskStateLocked(state)
        condition.broadcast()
        return packet
    }

    private func frontierLocked(at seconds: Double? = nil) -> Double? {
        let clock = seconds ?? sourceClock
        let videoEnd: Double?
        if let presentationCoverage {
            videoEnd = presentationCoverage.frontierSeconds(containing: clock,
                timeBaseNumerator: video.numerator, timeBaseDenominator: video.denominator)
        } else {
            videoEnd = videoCoverage.frontierSeconds(containing: clock,
                timeBaseNumerator: video.numerator, timeBaseDenominator: video.denominator)
        }
        let audioEnd = audio.flatMap { stream in
            audioCoverage.frontierSeconds(containing: clock,
                timeBaseNumerator: stream.numerator, timeBaseDenominator: stream.denominator)
        }
        return SoftwarePacketCoverage.combinedFrontier(
            video: videoEnd, audio: audioEnd, requiresAudio: audio != nil)
    }

    private func clearSourceMetadataLocked() {
        count = 0; bytes = 0; residentBytes = 0
        ended = false; failure = nil
        videoCoverage.reset(); audioCoverage.reset(); presentationCoverage?.reset()
        keyframes.removeAll(keepingCapacity: true)
    }

    private func copyDiskStateLocked(_ state: SoftwarePacketDiskFIFO.Snapshot) {
        count = state.count
        bytes = state.byteCount
        residentBytes = state.residentByteCount
        if let floor = state.oldestRetainedChunkID {
            keyframes.removeAll { $0.cursor.chunkID < floor }
        } else { keyframes.removeAll(keepingCapacity: true) }
    }

    private func produce() {
        defer { try? fifo.close() }
        while true {
            condition.lock()
            while !closed && !resetPending && (sourceRepositioning || ended || failure != nil || shouldParkLocked()) {
                condition.wait()
            }
            if closed { condition.unlock(); return }
            let token = sourceEpoch
            let reset = resetPending
            condition.unlock()

            if reset {
                operations.lock()
                do {
                    try fifo.reset()
                    condition.lock()
                    if token == sourceEpoch { resetPending = false }
                    condition.broadcast()
                    condition.unlock()
                } catch { recordFailure(error, token: token) }
                operations.unlock()
                continue
            }

            autoreleasepool {
                producePacket(token: token)
            }
        }
    }

    private func producePacket(token: UInt64) {
        do {
            let packet = try readSource { [self] in
                condition.lock(); defer { condition.unlock() }
                return token == sourceEpoch && !closed && !sourceRepositioning
            }
            guard let packet else {
                condition.lock()
                if token == sourceEpoch, !sourceRepositioning, !closed {
                    presentationCoverage?.finish()
                    ended = true
                }
                condition.broadcast()
                condition.unlock()
                return
            }
            let data = try packet.encoded()
            operations.lock()
            condition.lock()
            let valid = token == sourceEpoch && !closed && !sourceRepositioning
            condition.unlock()
            if valid {
                do {
                    let recordReservation = min(byteBudget, data.count)
                        + min(8, byteBudget - min(byteBudget, data.count))
                    try fifo.trimConsumed(toByteBudget: byteBudget - recordReservation)
                    let cursor = try fifo.append(data)
                    let state = fifo.snapshot
                    condition.lock()
                    if token == sourceEpoch, !closed, !sourceRepositioning {
                        copyDiskStateLocked(state)
                        if packet.streamIndex == video.index {
                            if presentationCoverage != nil {
                                presentationCoverage?.insert(pts: packet.pts)
                            } else {
                                videoCoverage.insert(pts: packet.pts, duration: packet.duration)
                            }
                            if packet.flags & 1 != 0, packet.pts != Int64.min,
                               video.numerator > 0, video.denominator > 0 {
                                let seconds = Double(packet.pts) * Double(video.numerator) / Double(video.denominator)
                                if seconds.isFinite { keyframes.append(Keyframe(seconds: seconds, cursor: cursor)) }
                                if keyframes.count > maximumKeyframes {
                                    keyframes.removeFirst(min(1024, keyframes.count))
                                }
                            }
                        } else if packet.streamIndex == audio?.index {
                            audioCoverage.insert(pts: packet.pts, duration: packet.duration)
                        }
                    }
                    condition.broadcast()
                    condition.unlock()
                } catch { recordFailure(error, token: token) }
            }
            operations.unlock()
        } catch { recordFailure(error, token: token) }
    }

    private func shouldParkLocked() -> Bool {
        // One source record can cross the budget. A consumed active chunk cannot be deleted before
        // cursor rollover, so residency also includes bounded protected chunk slack (not an
        // unbounded batch). Unknown time coverage is never guessed from bitrate.
        guard count > 0 else { return false }
        return residentBytes >= byteBudget || (frontierLocked().map { $0 - sourceClock >= forwardSeconds } ?? false)
    }

    private func recordFailure(_ error: Error, token: UInt64) {
        condition.lock(); defer { condition.unlock() }
        guard token == sourceEpoch, !closed else { return }
        failure = error
        resetPending = false
        condition.broadcast()
    }
}
