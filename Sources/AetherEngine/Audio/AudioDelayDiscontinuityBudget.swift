import Foundation

/// Bounds repeated Live source resets that prevent compressed audio alignment from producing a
/// matched interval. Pump admission evaluates it; no timer or recovery/route change is created.
final class AudioDelayDiscontinuityBudget: @unchecked Sendable {
    /// The source cannot supply a stable interval long enough for the requested correction.
    enum Failure: Error, Equatable, LocalizedError {
        /// Keeps the requested value visible instead of silently reducing it.
        case unmatchedDiscontinuities(delaySeconds: Double)

        /// Explains the source constraint and the explicit action the viewer can take.
        var errorDescription: String? {
            switch self {
            case .unmatchedDiscontinuities(let delay):
                return "Repeated source discontinuities prevent the requested \(delay) s audio delay from aligning. Reload a stable source or choose a smaller audio delay."
            }
        }
    }

    /// Shares the established native source-starvation allowance after legitimate delay warmup.
    let allowanceSeconds: TimeInterval
    /// A small correction keeps its existing pipeline and never activates this policy.
    private let enabled: Bool
    /// The exact requested offset belongs in a capacity/source explanation.
    private let delaySeconds: Double
    /// Guards numeric episode state only; never held across source or renderer work.
    private let lock = NSLock()
    /// Completed active intervals in the current episode; intentional pauses do not contribute.
    private var activeSeconds: TimeInterval = 0
    /// Monotonic start of the current playing interval, nil while intentionally paused.
    private var playingSince: TimeInterval?
    /// Last observed source epoch; the initial epoch is not a discontinuity.
    private var epoch: UInt64?
    /// Successful matched output clears this count together with the elapsed episode.
    private var unmatchedDiscontinuities = 0

    /// Starts paused; transport owners explicitly activate it when playback is requested.
    init(delaySeconds: Double) {
        self.delaySeconds = delaySeconds
        enabled = AudioDelayPolicy.usesAlignment(delaySeconds)
        allowanceSeconds = abs(delaySeconds) + HLSSegmentProducer.liveSourceStarvationTimeoutSeconds
    }

    /// Freezes elapsed time on pause and resumes the same episode without granting a new timeout.
    func setPlaying(_ playing: Bool, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.withLock {
            if playing {
                if playingSince == nil { playingSince = now }
            } else if let start = playingSince {
                activeSeconds += max(0, now - start)
                playingSince = nil
            }
        }
    }

    /// Observes source-order epochs before compressed scheduling; seams never restart the budget.
    func observeEpoch(_ value: UInt64, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        try lock.withLock {
            if let epoch, epoch != value { unmatchedDiscontinuities += 1 }
            epoch = value
            try checkLocked(at: now)
        }
    }

    /// A pump calls this between source operations, including stretches without another seam.
    func check(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        try lock.withLock { try checkLocked(at: now) }
    }

    /// Both streams have reached an admitted matched interval; a later outage gets a fresh episode.
    func noteMatchedOutput(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.withLock {
            activeSeconds = 0
            unmatchedDiscontinuities = 0
            if playingSince != nil { playingSince = now }
        }
    }

    /// An explicit seek/source replacement owns a new epoch namespace and alignment episode.
    /// Preserve transport intent so a paused seek cannot start charging active time.
    func resetForSourceChange(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.withLock {
            activeSeconds = 0
            unmatchedDiscontinuities = 0
            epoch = nil
            if playingSince != nil { playingSince = now }
        }
    }

    /// Only repeated unmatched resets are this policy's failure; ordinary starvation remains owned
    /// by the existing source watchdog. Paused owners cannot expire while their pump is parked.
    private func checkLocked(at now: TimeInterval) throws {
        guard enabled, let start = playingSince, unmatchedDiscontinuities >= 2 else { return }
        if activeSeconds + max(0, now - start) >= allowanceSeconds {
            throw Failure.unmatchedDiscontinuities(delaySeconds: delaySeconds)
        }
    }
}
