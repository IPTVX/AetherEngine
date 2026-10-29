import Foundation
@testable import AetherEngine

/// A deterministic media source without a seek/reopen transport, used to verify honest refusal.
final class ForwardOnlyMediaReader: IOReader, @unchecked Sendable {
    /// Thread-safe immutable media storage and cursor.
    private let reader: DataIOReader
    /// Counts source closure so a refused correction cannot silently retire its reader.
    private let closes = ProbeTestBox(0)
    /// Number of times the owning engine closed the source.
    var closeCount: Int { closes.value }
    /// Keeps disc recognition from issuing irrelevant random reads against this stream.
    var discImageProbeEnabled: Bool { false }

    /// Constructs an independent forward-only cursor over synthetic fixture media.
    init(data: Data) { reader = DataIOReader(data: data) }
    /// Delivers bytes on the real demux thread.
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        reader.read(buffer, size: size)
    }
    /// Rejects all random access, including length queries.
    func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
    /// Records ownership release without blocking teardown.
    func close() { closes.update { $0 += 1 } }
}
