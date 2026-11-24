import Foundation
@testable import AetherEngine

/// Serves a synthetic recording as an open Live source whose exhausted tail waits for cancellation.
final class ProbeLiveTailReader: IOReader, @unchecked Sendable {
    /// Records source access so a ring operation cannot silently reopen or reposition the source.
    private let reader: ProbeRecordingReader

    /// A probe may inspect EOF; only the subsequent playback source is kept open.
    private let armed = ProbeTestBox(false)

    /// Separates the parked Live tail from the finite bytes already delivered into the ring.
    private let tailGate = ProbeTestGate()

    /// Prevents the custom source from being mistaken for a disc image.
    let discImageProbeEnabled = false

    /// Whether playback has reached the exhausted source tail without receiving an EOF result.
    var isBlocked: Bool { tailGate.entered && !tailGate.isOpen }

    /// Source cancellations observed independently from the retained playback host.
    var cancellationCount: Int { reader.cancelCount }

    /// Source close calls distinguish ring-only seeks from a pipeline reopen.
    var closeCount: Int { reader.closeCount }

    /// Includes size queries; a ring-only audio pick must leave this count unchanged.
    var seekCount: Int { reader.seeks.count }

    /// Short reads prevent a bounded stream-info probe from pre-reading the entire fixture.
    init(data: Data, maxReadSize: Int = 1024) {
        reader = ProbeRecordingReader(data: data, chunkSize: maxReadSize)
    }

    /// Called after the playback host is constructed, when container probing has completed.
    func arm() { armed.update { $0 = true } }

    /// Releases the tail before test teardown, without inventing additional media packets.
    func release() { tailGate.open() }

    /// Parks only EOF, so all remaining fixture packets can first become resident in the ring.
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        let result = reader.read(buffer, size: size)
        if result == 0, armed.value { tailGate.wait() }
        return result
    }

    /// Preserves the fixture's normal probe capabilities and records any later source reposition.
    func seek(offset: Int64, whence: Int32) -> Int64 {
        reader.seek(offset: offset, whence: whence)
    }

    /// Wakes a blocked read before forwarding cancellation to the recorded source.
    func cancel() {
        tailGate.open()
        reader.cancel()
    }

    /// Wakes a blocked read before recording final source release.
    func close() {
        tailGate.open()
        reader.close()
    }
}
