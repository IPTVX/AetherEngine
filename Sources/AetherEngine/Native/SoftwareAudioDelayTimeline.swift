import Foundation

/// Keeps compressed alignment and clock decisions on the video's source axis while decoders and
/// taps retain their original timestamps. The ordinary lip-sync path is deliberately unchanged.
struct SoftwareAudioDelayTimeline {
    /// The offset ultimately applied by AudioOutput, in seconds.
    let delaySeconds: Double

    /// Large corrections need compressed alignment rather than decoded renderer buffering.
    var requiresAlignment: Bool { AudioDelayPolicy.usesAlignment(delaySeconds) }

    /// The audio sample's actual presentation time on the video's clock.
    func audioPresentationTime(_ sourceSeconds: Double) -> Double {
        sourceSeconds + (requiresAlignment ? delaySeconds : 0)
    }

    /// Earliest source interval needed for a seek that preserves the requested video position.
    func sourceReadStart(videoPosition: Double) -> Double {
        requiresAlignment ? max(0, min(videoPosition, videoPosition - delaySeconds)) : videoPosition
    }

    /// Live starts only after both streams can provide the requested offset; VOD never skips video.
    func videoAnchor(sourceOrigin: Double, requestedPosition: Double, isLive: Bool) -> Double {
        isLive && requiresAlignment ? sourceOrigin + max(delaySeconds, 0) : requestedPosition
    }

    /// Intersects available source history with the audio interval needed by each video moment.
    /// Additional internal retention never expands the public DVR window or advertises future audio.
    func playableVideoRange(sourceFloor: Double, sourceEdge: Double,
                            publicWindow: Double?) -> ClosedRange<Double>? {
        let lower = sourceFloor + (requiresAlignment ? max(delaySeconds, 0) : 0)
        let upper = sourceEdge + (requiresAlignment ? min(delaySeconds, 0) : 0)
        let floor = publicWindow.map { max(lower, upper - $0) } ?? lower
        return upper >= floor ? floor...upper : nil
    }

    /// Required shifted media was evicted before a Live reader could obtain it.
    enum RecoveryFailure: Error, Equatable, LocalizedError {
        /// The retained source interval cannot hold the requested correction.
        case insufficientRetainedHistory(delaySeconds: Double)

        /// Explains why retrying the same cursor cannot create the missing history.
        var errorDescription: String? {
            switch self {
            case .insufficientRetainedHistory(let delay):
                return "The Live buffer cannot retain a playable interval for the requested \(delay) s audio delay. Free storage or choose a smaller audio delay, then reload the stream."
            }
        }
    }

    /// An evicted aligned reader either recovers to a complete interval or fails immediately.
    /// An intentional pause defers the decision, including pause before the first visible frame.
    func evictionRecoveryTarget(sourceFloor: Double?, sourceEdge: Double, isPlaying: Bool) throws -> Double? {
        if !isPlaying { return nil }
        guard let sourceFloor, let range = playableVideoRange(
            sourceFloor: sourceFloor, sourceEdge: sourceEdge, publicWindow: nil) else {
            throw RecoveryFailure.insufficientRetainedHistory(delaySeconds: delaySeconds)
        }
        return range.lowerBound
    }

    /// Whether a decoded audio sample belongs to the requested video interval. Missing audio at
    /// either finite-title boundary is intentional silence, rather than a reason to move video.
    func admitsAudio(sourceSeconds: Double, videoStart: Double, videoEnd: Double?) -> Bool {
        if !requiresAlignment { return true }
        let presentation = audioPresentationTime(sourceSeconds)
        if let videoEnd, presentation >= videoEnd { return false }
        return presentation >= videoStart
    }
}
