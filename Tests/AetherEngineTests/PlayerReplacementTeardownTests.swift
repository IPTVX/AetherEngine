import Foundation
import Testing
@testable import AetherEngine

@Suite("Player replacement teardown")
@MainActor
struct PlayerReplacementTeardownTests {
    @Test("Stop-and-wait leaves an idle engine without an active native session")
    func stopAndWaitForSourceTeardown_clearsNativeSession() async throws {
        let engine = try AetherEngine()
        engine.nativeVideoSession = HLSVideoEngine(
            url: URL(fileURLWithPath: "/nonexistent/player-replacement.mkv"),
            dvModeAvailable: false
        )

        await engine.stopAndWaitForSourceTeardown()

        #expect(engine.state == .idle)
        #expect(engine.nativeVideoSession == nil)
    }
}
