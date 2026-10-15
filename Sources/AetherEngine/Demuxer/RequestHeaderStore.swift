import Foundation

/// AE#792: the HTTP headers a session's source requests carry, as one value every reader of that
/// session reads at request time instead of a copy each one froze at its open.
///
/// A credential that rotates under a playing session (a bearer token that lives an hour) changes
/// nothing about the session except this value, and every request an `AVIOReader` builds already
/// goes through one place (`headers(for:)`), so the value is the only thing that was frozen. The
/// session creates one store per load, hands it to the readers it opens (through
/// `DemuxerOpenProfile.requestHeaders`) and to the producer's reopens, and
/// `AetherEngine.updateRequestHeaders(_:)` replaces the value in it. A request already in flight
/// finishes with the headers it was sent with; the next one carries the new set.
///
/// Redirect scoping is not this type's business: `RedirectHeaderPolicy` still decides which of
/// these headers a given target may see, on the value read here.
final class RequestHeaderStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: String]

    init(_ headers: [String: String]) {
        value = headers
    }

    var current: [String: String] {
        lock.withLock { value }
    }

    func replace(_ headers: [String: String]) {
        lock.withLock { value = headers }
    }
}
