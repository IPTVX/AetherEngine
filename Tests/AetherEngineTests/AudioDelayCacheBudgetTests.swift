import Foundation
import Testing
@testable import AetherEngine

/// The large-delay cache partition must backpressure playable saturation rather than failing it.
struct AudioDelayCacheBudgetTests {
    /// Consumed optional history makes room while the current and future response remain valid.
    @Test
    func saturatedCacheContinuesAfterConsumerAdvance() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 20, retentionBudgetBytes: 180)
        defer { cache.close() }
        #expect(cache.store(index: 0, data: Data(repeating: 1, count: 60)))
        #expect(cache.store(index: 1, data: Data(repeating: 2, count: 60)))
        cache.declareTarget(0)
        if case .waitForConsumer = cache.admitStagingBytes(100, budget: 180) {} else {
            Issue.record("A full playable forward cache must wait for consumption")
        }
        cache.declareTarget(1)
        if case .accepted = cache.admitStagingBytes(100, budget: 180) {} else {
            Issue.record("Consumed history must release staging headroom")
        }
        #expect(cache.peek(index: 0) == nil)
        #expect(cache.peek(index: 1) != nil)
        #expect(cache.store(index: 2, data: Data(repeating: 3, count: 100)))
        #expect(cache.totalBytes <= 180)
        #expect(cache.peek(index: 2) != nil)
    }

    /// A missing seek target cannot consume later cached segments to release its own admission.
    @Test
    func coldSeekEvictsOptionalForwardExtrasInsteadOfWaiting() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 20, retentionBudgetBytes: 100)
        defer { cache.close() }
        #expect(cache.store(index: 101, data: Data(repeating: 1, count: 80)))
        cache.declareTarget(100)
        if case .accepted = cache.admitStagingBytes(30, budget: 100) {} else {
            Issue.record("A cold seek must make room for its missing current segment")
        }
        #expect(cache.peek(index: 101) == nil)
        #expect(cache.store(index: 100, data: Data(repeating: 2, count: 30)))
        #expect(cache.peek(index: 100) != nil)
    }

    /// A single required staging record that cannot fit is a real capacity failure, not a park.
    @Test
    func oversizedRequiredSegmentIsRejected() {
        let cache = SegmentCache()
        defer { cache.close() }
        if case .insufficientCapacity = cache.admitStagingBytes(181, budget: 180) {} else {
            Issue.record("An oversized mandatory segment cannot become admissible by waiting")
        }
    }
}
