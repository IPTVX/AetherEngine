import AVFoundation

/// Keeps a tvOS HDMI route in Dolby Atmos while the engine's `AVPlayer` plays an APAC track.
///
/// tvOS hands APAC to the receiver as Dolby MAT, but measured on an Apple TV 4K (tvOS 27.2) with an
/// Atmos soundbar that was not enough: the route stayed at 2 output channels and the soundbar showed
/// no Atmos, although `AVAudioSession` reported a MAT format throughout. A second, unmuted player
/// looping a silent E-AC-3 stream signalled as Dolby Atmos switched the route to 32 channels and the
/// soundbar to Atmos before the first frame, and kept it there across a seek.
///
/// The stream (`Resources/silent-atmos.mp4`, written bit by bit by `Scripts/make-silent-atmos.swift`)
/// decodes to digital silence, so nothing is mixed into the programme. It plays only while the host
/// player plays or waits to play an item `playsAPAC` accepts, and is released otherwise, since a
/// prerolled E-AC-3 stream would compete with other audio.
@MainActor
final class AtmosOutputActivator {
    static let silentAtmosStream = Bundle.module.url(forResource: "silent-atmos", withExtension: "mp4")!

    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private weak var host: AVPlayer?
    private var playsAPAC: @MainActor (AVPlayerItem) -> Bool = { _ in false }
    private var observations: [NSKeyValueObservation] = []
    private var selectionObserver: NSObjectProtocol?

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
    }

    /// Follows `host`: its item, its audio selection and whether it is playing.
    func attach(to host: AVPlayer, playsAPAC: @escaping @MainActor (AVPlayerItem) -> Bool) {
        detach()
        self.host = host
        self.playsAPAC = playsAPAC
        // A host play() changes timeControlStatus synchronously on the main thread, so the stream
        // starts inside that call, ahead of the APAC output.
        observations = [
            host.observe(\.currentItem, options: [.initial]) { [weak self] _, _ in
                Self.onMain { self?.follow(self?.host?.currentItem) }
            },
            host.observe(\.timeControlStatus) { [weak self] _, _ in
                Self.onMain { self?.update() }
            },
        ]
    }

    func detach() {
        observations.forEach { $0.invalidate() }
        observations = []
        host = nil
        follow(nil)
    }

    private func follow(_ item: AVPlayerItem?) {
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = item.map {
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: $0, queue: .main
            ) { [weak self] _ in
                Self.onMain { self?.update() }
            }
        }
        update()
    }

    private func update() {
        guard let host, let item = host.currentItem, playsAPAC(item) else {
            release()
            return
        }
        guard host.timeControlStatus != .paused else {
            player.pause()
            return
        }
        if looper == nil {
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: Self.silentAtmosStream))
        }
        player.play()
    }

    private func release() {
        guard let looper else { return }
        player.pause()
        looper.disableLooping()
        self.looper = nil
        player.removeAllItems()
    }

    private nonisolated static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            Task { @MainActor in body() }
        }
    }
}

extension AetherEngine {
    /// tvOS only: the switch is an HDMI one, and on iOS and macOS a second unmuted player beside the
    /// engine's would compete with it for Now Playing and the audio session for no gain.
    func followAtmosOutput() {
        #if os(tvOS)
        guard let player = currentAVPlayer else {
            atmosOutputActivator?.detach()
            return
        }
        let activator = atmosOutputActivator ?? AtmosOutputActivator()
        atmosOutputActivator = activator
        activator.attach(to: player) { [weak self] _ in self?.nativeVideoSession?.audioIsAPAC == true }
        #endif
    }
}
