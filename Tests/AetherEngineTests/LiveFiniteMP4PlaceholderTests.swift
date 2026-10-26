import Foundation
import Testing
@testable import AetherEngine

/// A finite MP4 returned for a Live endpoint must finish opening instead of refetching its body forever.
@Suite("Finite MP4 placeholder on a Live endpoint")
struct LiveFiniteMP4PlaceholderTests {
    // Failure modes:
    // - Live metadata suppresses the finite body's size and EOF, so container probing keeps reading.
    // - Treating every finite response as EOF breaks genuine Live bursts that must reconnect.
    // - Cancelling an opening demuxer closes its native state before the worker has unwound.

    /// Exercises both a plain finite response and an origin that fulfills advertised byte ranges.
    enum ResponseMode: CaseIterable, Equatable, Sendable {
        /// Returns the complete finite resource with HTTP 200 for every request.
        case wholeBody200
        /// Answers valid byte ranges with 206 and ranges past the finite end with 416.
        case honorRanges
    }

    /// Bounds startup latency on an isolated worker, then interrupts and joins that worker before returning.
    @Test(
        "A finite video/mp4 opens within two seconds under either declared media kind",
        .timeLimit(.minutes(1)),
        arguments: [false, true], ResponseMode.allCases
    )
    func test_open_finiteMP4_completesWithinStartupBudget(
        isLive: Bool,
        responseMode: ResponseMode
    ) async throws {
        let bytes = try ProbeTestFixtures.decode(AtmosDetectionProbeIntegrationTests.videoOnlyBase64)
        let origin = try ProbeHTTPTestOrigin(
            data: bytes,
            response: { request, _ in
                Self.response(
                    for: request,
                    body: bytes,
                    mode: responseMode
                )
            }
        )
        let demuxer = Demuxer()
        let stages = ProbeTestBox<[String]>([])
        demuxer.onOpenProgress = { stage in
            stages.update { $0.append(String(describing: stage)) }
        }
        defer {
            demuxer.markClosed()
            origin.stop()
        }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/live.ts"))
        let job = ProbeTestJob {
            // Only the worker releases native state; markClosed merely interrupts the current open.
            defer { demuxer.close() }
            try demuxer.open(url: url, isLive: isLive)
            return (
                hasVideo: demuxer.videoStreamIndex >= 0,
                finiteLiveResource: demuxer.confirmedFiniteLiveResource
            )
        }

        let deadline = ContinuousClock.now + .seconds(2)
        while !job.isFinished, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let completedWithinBudget = job.isFinished
        let observedStages = stages.value
        let requestCount = origin.requests.count
        // Cancellation must precede close, and the worker must finish even when the latency assertion fails.
        demuxer.markClosed()
        origin.stop()
        try await waitFor { job.isFinished }
        let outcome = try await job.outcome()

        #expect(
            completedWithinBudget,
            "isLive=\(isLive), mode=\(responseMode), requests=\(requestCount), stages=\(observedStages)"
        )
        if completedWithinBudget {
            let opened = try outcome.get()
            #expect(opened.hasVideo, "The finite fixture must resolve its video stream")
            #expect(opened.finiteLiveResource == isLive, "The session must receive the HTTP reader's finite-resource proof")
            #expect(observedStages.contains("containerOpened"))
            #expect(observedStages.contains("streamsProbed"))
        }
        try await waitFor { origin.isStopped }
        #expect(origin.failure == nil)
    }

    /// A normal finite custom source has a duration but provides no HTTP Live resource evidence.
    @Test("A finite custom container does not establish finite HTTP Live resource proof")
    func test_customSource_finiteDuration_doesNotClaimHTTPProof() throws {
        let bytes = try ProbeTestFixtures.decode(AtmosDetectionProbeIntegrationTests.videoOnlyBase64)
        let demuxer = Demuxer()
        defer { demuxer.close() }

        try demuxer.open(reader: DataIOReader(data: bytes), formatHint: "mp4", isLive: false)

        #expect(demuxer.duration > 0)
        #expect(!demuxer.confirmedFiniteLiveResource)
    }

    /// Produces only loopback fixture responses, including Content-Type and finite length on every success.
    private static func response(
        for request: ProbeHTTPTestOrigin.Request,
        body: Data,
        mode: ResponseMode
    ) -> Data {
        var start = 0
        var end = body.count - 1
        var status = "200 OK"
        var contentRange = ""
        if mode == .honorRanges, let range = request.range {
            let parts = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            if range.hasPrefix("bytes="), parts.count == 2 {
                if parts[0].isEmpty, let suffix = Int(parts[1]), suffix > 0 {
                    start = max(0, body.count - suffix)
                } else if let first = Int(parts[0]), first >= 0 {
                    start = first
                    if let last = Int(parts[1]) { end = min(end, last) }
                } else {
                    start = body.count
                }
            } else {
                start = body.count
            }
            if start >= body.count || end < start {
                return Data(("HTTP/1.1 416 Range Not Satisfiable\r\n"
                    + "Content-Range: bytes */\(body.count)\r\n"
                    + "Content-Length: 0\r\nConnection: close\r\n\r\n").utf8)
            }
            status = "206 Partial Content"
            contentRange = "Content-Range: bytes \(start)-\(end)/\(body.count)\r\n"
        }
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: video/mp4\r\n"
            + "Content-Length: \(end - start + 1)\r\n"
            + contentRange
            + "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        var response = Data(headers.utf8)
        if request.method != "HEAD" {
            response.append(body.subdata(in: start..<(end + 1)))
        }
        return response
    }
}
