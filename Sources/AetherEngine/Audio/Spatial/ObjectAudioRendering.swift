import Foundation

/// How a TrueHD track carrying Dolby Atmos, or a DTS-HD Master Audio track carrying DTS:X, is
/// delivered.
///
/// Apple TV cannot bitstream TrueHD or DTS-HD, so `audioBridgeMode` decodes their 7.1 channel
/// presentation and the objects and heights are lost. `.apac` keeps them: the engine renders the
/// objects and heights into the listener's speaker bed and delivers it as Apple Positional Audio,
/// which tvOS sends to an Atmos receiver as Dolby MAT. The price is a lossy encode (several Mbit/s)
/// in place of the lossless 7.1, which is why this is the host's choice and not the engine's.
///
/// Applies to TrueHD sources FFmpeg identifies as Atmos (profile 30) and to DTS-HD Master Audio that
/// LibDTSX confirms as DTS:X on its first frames, at 48 kHz, and only on OS 26 and later, where the
/// APAC encoder API exists. Everything else keeps `audioBridgeMode`.
public enum ObjectAudioRendering: Equatable, Sendable {
    case off
    /// Render into `layout`, which should match the speakers the receiver actually drives.
    case apac(SpatialSpeakerLayout)

    /// The only rate object audio is rendered at. TrueHD Atmos and DTS:X are authored at 48 kHz.
    static let sampleRate = 48_000

    var layout: SpatialSpeakerLayout? {
        if case .apac(let layout) = self { return layout }
        return nil
    }
}
