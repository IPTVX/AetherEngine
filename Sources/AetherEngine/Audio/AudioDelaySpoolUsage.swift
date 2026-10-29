import Foundation

/// Numeric residency shared by all alignment producers of one native session. Old producer cleanup
/// removes only its entry, so it cannot erase a replacement producer's reservation/accounting.
final class AudioDelaySpoolUsage: @unchecked Sendable {
    /// Protects fixed-size producer accounting only; no storage/source work occurs under this lock.
    private let lock = NSLock()
    /// Logical resident bytes keyed by producer identity.
    private var bytes: [UUID: Int] = [:]
    /// Total disk residency included in the existing session's retention claim.
    var total: Int { lock.withLock { bytes.values.reduce(0, +) } }
    /// Other producers' residency shares the same hard session allowance.
    func otherBytes(excluding owner: UUID) -> Int {
        lock.withLock { bytes.filter { $0.key != owner }.values.reduce(0, +) }
    }
    /// Records one producer's current logical disk allocation; zero retires that producer.
    func set(_ value: Int, for owner: UUID) {
        lock.withLock { if value == 0 { bytes.removeValue(forKey: owner) } else { bytes[owner] = value } }
    }
}
