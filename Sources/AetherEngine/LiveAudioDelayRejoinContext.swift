import Foundation

/// Carries one owned audio correction through the existing reload/load call chain without a public
/// option. The original generation prevents tasks spawned by retired callbacks inheriting ownership.
struct LiveAudioDelayRejoinContext: Sendable {
    /// Identifies the coalesced correction whose teardown may keep its own task alive.
    let ownerID: UUID
    /// The session generation before this correction invalidates it through normal load teardown.
    let generation: UInt64
    /// Scoped to the reload call, so ordinary loads keep their existing teardown behavior.
    @TaskLocal static var current: LiveAudioDelayRejoinContext?
}
