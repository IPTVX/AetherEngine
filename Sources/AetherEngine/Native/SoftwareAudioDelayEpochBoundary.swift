/// Commits source changes only when their compressed records leave alignment queues. Observing a
/// future source epoch during read-ahead must never reset the decoder serving queued older media.
struct SoftwareAudioDelayEpochBoundary {
    /// The last epoch actually handed to the decoder, independent of the source reader's frontier.
    private var consumed: UInt64 = 0

    /// Returns true exactly once when the consumer must drain and reset before a new source epoch.
    mutating func consumes(_ epoch: UInt64) -> Bool {
        if epoch == consumed { return false }
        consumed = epoch
        return true
    }
}
