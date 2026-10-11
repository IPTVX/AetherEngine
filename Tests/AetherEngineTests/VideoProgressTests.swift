import Testing
@testable import AetherEngine

struct VideoProgressTests {
    private func warmed() -> VideoFrameProgress {
        var monitor = VideoFrameProgress()
        for time in [0.0, 0.1, 0.2] {
            _ = monitor.observe(frame: time, clock: time, now: time, eligible: true, frameDuration: 0.04)
        }
        return monitor
    }

    @Test("video output stops while the item clock advances, then resumes once")
    func shortVideoOnlyGap() {
        var monitor = warmed()
        let began = monitor.observe(frame: nil, clock: 0.6, now: 0.6, eligible: true, frameDuration: 0.04)
        guard case .began(let age, let advance) = began else { Issue.record("missing output gap"); return }
        #expect(abs(age - 0.4) < 0.000001 && abs(advance - 0.4) < 0.000001)
        #expect(monitor.observe(frame: nil, clock: 0.7, now: 0.7, eligible: true, frameDuration: 0.04) == nil)
        let ended = monitor.observe(frame: 0.8, clock: 0.8, now: 0.8, eligible: true, frameDuration: 0.04)
        guard case .ended(let age) = ended else { Issue.record("missing output recovery"); return }
        #expect(abs(age - 0.6) < 0.000001)
    }

    @Test("a paused clock, unavailable output, seek or inactive rendering cannot report a freeze")
    func exclusions() {
        var monitor = warmed()
        #expect(monitor.observe(frame: nil, clock: 0.2, now: 0.7, eligible: true, frameDuration: 0.04) == nil)
        _ = monitor.observe(frame: nil, clock: 0.2, now: 0.8, eligible: false, frameDuration: 0.04)
        #expect(monitor.samples == 0)
        #expect(monitor.observe(frame: nil, clock: 20, now: 1, eligible: true, frameDuration: 0.04) == nil)
        monitor = warmed()
        #expect(monitor.observe(frame: nil, clock: 10, now: 0.7, eligible: true, frameDuration: 0.04) == nil)
        #expect(monitor.samples == 0)
    }

    @Test("low-frame-rate content gets its own observation allowance")
    func lowFrameRate() {
        var monitor = warmed()
        #expect(monitor.observe(frame: nil, clock: 0.8, now: 0.8, eligible: true, frameDuration: 0.5) == nil)
    }

    @Test("compressed timestamp gaps and source clock resets are separate")
    func packetGaps() {
        var monitor = VideoPacketProgress()
        for index in 0..<8 { #expect(monitor.observe(Double(index) * 0.04) == nil) }
        let gap = monitor.observe(0.8)
        #expect(gap != nil)
        #expect(abs((gap?.seconds ?? 0) - 0.52) < 0.000001)
        #expect(monitor.observe(0) == nil)
        #expect(monitor.observe(0.04) == nil)
        #expect(monitor.observe(.nan) == nil)
    }
}
