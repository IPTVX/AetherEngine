import Testing
@testable import AetherEngine

/// Uses explicit monotonic times to prove pause handling without sleeping or source I/O.
@Suite("Audio delay discontinuity budget")
struct AudioDelayDiscontinuityBudgetTests {
    /// Repeated epochs consume one continuous allowance, rather than granting a timeout per seam.
    @Test(arguments: [-180.0, 180.0])
    func repeatedSeamsExhaustOneActiveEpisode(delay: Double) throws {
        let budget = AudioDelayDiscontinuityBudget(delaySeconds: delay)
        budget.setPlaying(true, at: 0)
        try budget.observeEpoch(0, at: 0)
        try budget.observeEpoch(1, at: 100)
        try budget.observeEpoch(2, at: 200)
        #expect(throws: AudioDelayDiscontinuityBudget.Failure.unmatchedDiscontinuities(delaySeconds: delay)) {
            try budget.check(at: budget.allowanceSeconds)
        }
    }

    /// A long viewer pause neither expires the policy nor resets the active time already spent.
    @Test
    func pauseFreezesAndResumeKeepsElapsedTime() throws {
        let budget = AudioDelayDiscontinuityBudget(delaySeconds: 180)
        budget.setPlaying(true, at: 0)
        try budget.observeEpoch(0, at: 0)
        try budget.observeEpoch(1, at: 20)
        try budget.observeEpoch(2, at: 40)
        budget.setPlaying(false, at: 100)
        try budget.check(at: 10_000)
        budget.setPlaying(true, at: 10_000)
        try budget.check(at: 10_114)
        #expect(throws: AudioDelayDiscontinuityBudget.Failure.unmatchedDiscontinuities(delaySeconds: 180)) {
            try budget.check(at: 10_115)
        }
    }

    /// Real matched output resets both elapsed time and seams before a later recovery episode.
    @Test
    func matchedOutputStartsANewRecoveryEpisode() throws {
        let budget = AudioDelayDiscontinuityBudget(delaySeconds: 180)
        budget.setPlaying(true, at: 0)
        try budget.observeEpoch(0, at: 0)
        try budget.observeEpoch(1, at: 50)
        try budget.observeEpoch(2, at: 100)
        budget.noteMatchedOutput(at: 200)
        try budget.observeEpoch(3, at: 250)
        try budget.observeEpoch(4, at: 300)
        try budget.check(at: 414)
        #expect(throws: AudioDelayDiscontinuityBudget.Failure.unmatchedDiscontinuities(delaySeconds: 180)) {
            try budget.check(at: 415)
        }
    }

    /// Viewer repositioning starts a new source epoch namespace and preserves an explicit pause.
    @Test
    func explicitSourceChangeResetsEpochIdentityWhilePaused() throws {
        let budget = AudioDelayDiscontinuityBudget(delaySeconds: 180)
        budget.setPlaying(true, at: 0)
        try budget.observeEpoch(10, at: 0)
        try budget.observeEpoch(11, at: 100)
        budget.setPlaying(false, at: 200)
        budget.resetForSourceChange(at: 10_000)
        try budget.observeEpoch(0, at: 20_000)
        try budget.check(at: 20_000)
        budget.setPlaying(true, at: 20_000)
        try budget.observeEpoch(1, at: 20_100)
        try budget.observeEpoch(2, at: 20_200)
        try budget.check(at: 20_214)
        #expect(throws: AudioDelayDiscontinuityBudget.Failure.unmatchedDiscontinuities(delaySeconds: 180)) {
            try budget.check(at: 20_215)
        }
    }

    /// Small corrections and a stable long warmup remain under their established policies.
    @Test
    func stableSourceAndLegacyOffsetsDoNotFail() throws {
        for delay in [-2.0, 0, 2.0, 180.0] {
            let budget = AudioDelayDiscontinuityBudget(delaySeconds: delay)
            budget.setPlaying(true, at: 0)
            try budget.observeEpoch(0, at: 0)
            if abs(delay) <= 2 {
                try budget.observeEpoch(1, at: 1)
                try budget.observeEpoch(2, at: 2)
            }
            try budget.check(at: 100_000)
        }
    }
}
