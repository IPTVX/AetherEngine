// #377 (Rasmusmart57): the origin refuses new requests for about four minutes at a stretch, and a
// reader that asks for a new range every 8 to 16 MB of drain will ask inside one of those windows on
// any long file. `LoadOptions.heldSourceConnection` answers once and pulls, over a transport whose
// reads are demand driven, so the framing that `URLSession` would normally do is ours.
//
// These tests measure the framing, because that is the part that can be wrong quietly: a chunk size
// line delivered as media bytes corrupts a container without an error anywhere, and a Range header
// sent twice is a different request than the one intended. The backpressure itself is NOT testable
// on a loopback (TCP closes the window before any buffer of interest fills, which is why the
// suspend defect in #220 survived every local test it ever had); what is measurable here is that the
// pull budget is the only thing that decides how much comes off the wire, and that a zero budget
// ends the connection after exactly one request.
import Foundation
import Testing
@testable import AetherEngine

/// Records what the connection reports and answers pull budgets from a script.
private final class RecordingHeldDelegate: HeldSourceConnectionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _body = Data()
    private var _statuses: [Int] = []
    private var _ended = false
    private var _endError: Error?
    private var budgets: [Int]
    private let defaultBudget: Int
    private let finished = DispatchSemaphore(value: 0)
    /// Refuse the response, the way the reader does for a 429 or a Range-ignoring 200.
    private let acceptResponse: @Sendable (Int) -> Bool

    init(budgets: [Int] = [], defaultBudget: Int = 64 * 1024,
         acceptResponse: @escaping @Sendable (Int) -> Bool = { $0 == 200 || $0 == 206 }) {
        self.budgets = budgets
        self.defaultBudget = defaultBudget
        self.acceptResponse = acceptResponse
    }

    var body: Data { lock.lock(); defer { lock.unlock() }; return _body }
    var statuses: [Int] { lock.lock(); defer { lock.unlock() }; return _statuses }
    var endError: Error? { lock.lock(); defer { lock.unlock() }; return _endError }

    @discardableResult
    func waitForEnd(seconds: Double = 20) -> Bool {
        finished.wait(timeout: .now() + seconds) == .success
    }

    func heldConnection(_ connection: HeldSourceConnection,
                        didReceive response: HTTPURLResponse,
                        from url: URL) -> Bool {
        lock.lock()
        _statuses.append(response.statusCode)
        lock.unlock()
        return acceptResponse(response.statusCode)
    }

    func heldConnection(_ connection: HeldSourceConnection, didReceive data: Data) {
        lock.lock()
        _body.append(data)
        lock.unlock()
    }

    func heldConnectionPullBudget(_ connection: HeldSourceConnection) -> Int {
        lock.lock(); defer { lock.unlock() }
        if budgets.isEmpty { return defaultBudget }
        return budgets.removeFirst()
    }

    func heldConnection(_ connection: HeldSourceConnection, didEndWith error: Error?) {
        lock.lock()
        _ended = true
        _endError = error
        lock.unlock()
        finished.signal()
    }
}

@Suite("#377 held source connection")
struct Issue377HeldConnectionTests {

    // MARK: - Request framing

    @Test("the request carries the range, the host and the path with its query")
    func requestFraming() throws {
        let url = try #require(URL(string: "https://cdn.example.com/media/file.mkv?token=abc&x=1"))
        let bytes = HeldSourceConnection.requestBytes(
            target: url, host: "cdn.example.com", port: 443, secure: true,
            offset: 14_652_209_616, extraHeaders: [:], userAgent: "AetherEngine/test")
        let text = String(decoding: bytes, as: UTF8.self)

        #expect(text.hasPrefix("GET /media/file.mkv?token=abc&x=1 HTTP/1.1\r\n"))
        #expect(text.contains("\r\nHost: cdn.example.com\r\n"))
        #expect(text.contains("\r\nRange: bytes=14652209616-\r\n"))
        #expect(text.contains("\r\nUser-Agent: AetherEngine/test\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test("a non-default port rides in Host, because an origin may route on it")
    func hostCarriesNonDefaultPort() throws {
        let url = try #require(URL(string: "http://192.168.1.10:8096/Videos/1/stream"))
        let text = String(decoding: HeldSourceConnection.requestBytes(
            target: url, host: "192.168.1.10", port: 8096, secure: false,
            offset: 0, extraHeaders: [:], userAgent: nil), as: UTF8.self)
        #expect(text.contains("\r\nHost: 192.168.1.10:8096\r\n"))
        #expect(!text.contains("User-Agent:"))
    }

    @Test("a source header set wins without duplicating a header the request already sends")
    func extraHeadersDoNotDuplicate() throws {
        let url = try #require(URL(string: "https://jellyfin.example.com/Items/1/Download"))
        let text = String(decoding: HeldSourceConnection.requestBytes(
            target: url, host: "jellyfin.example.com", port: 443, secure: true, offset: 0,
            extraHeaders: ["X-Emby-Token": "secret", "User-Agent": "Sodalite/1.0", "Range": "bytes=99-"],
            userAgent: "AetherEngine/test"), as: UTF8.self)

        #expect(text.contains("\r\nX-Emby-Token: secret\r\n"))
        // The caller's User-Agent replaces the default rather than joining it.
        #expect(text.contains("\r\nUser-Agent: Sodalite/1.0\r\n"))
        #expect(!text.contains("AetherEngine/test"))
        // A caller cannot smuggle a second Range in: the offset is the reader's to decide.
        #expect(text.components(separatedBy: "Range: ").count == 2)
        #expect(text.contains("\r\nRange: bytes=0-\r\n"))
    }

    // MARK: - Chunked framing

    @Test("a chunked body decodes across arbitrary feed boundaries")
    func chunkedAcrossFeeds() throws {
        let wire = Data("4\r\nWiki\r\n7\r\npedia i\r\nB\r\nn \r\nchunks.\r\n0\r\n\r\n".utf8)
        // One byte at a time is the worst split a socket can hand over, and the state machine has
        // to survive a size line arriving in pieces.
        for feedSize in [1, 3, 7, wire.count] {
            let decoder = ChunkedBodyDecoder()
            var out = Data()
            var offset = 0
            while !decoder.isComplete {
                if let piece = try decoder.take(upTo: 4096) {
                    out.append(piece)
                    continue
                }
                guard offset < wire.count else { break }
                let end = min(offset + feedSize, wire.count)
                decoder.feed(wire.subdata(in: offset..<end))
                offset = end
            }
            #expect(decoder.isComplete, "feed size \(feedSize) never reached the terminating chunk")
            #expect(String(decoding: out, as: UTF8.self) == "Wikipedia in \r\nchunks.")
        }
    }

    @Test("a chunk size line with an extension is still a size, and trailers end the body")
    func chunkedExtensionsAndTrailers() throws {
        let decoder = ChunkedBodyDecoder()
        decoder.feed(Data("5;name=value\r\nhello\r\n0\r\nX-Checksum: 1\r\n\r\n".utf8))
        let out = try decoder.take(upTo: 4096)
        #expect(String(decoding: out ?? Data(), as: UTF8.self) == "hello")
        #expect(try decoder.take(upTo: 4096) == nil)
        #expect(decoder.isComplete)
    }

    @Test("a size line that is not hex is a framing error rather than media bytes")
    func chunkedRejectsBadSize() {
        let decoder = ChunkedBodyDecoder()
        decoder.feed(Data("not-a-size\r\nhello\r\n".utf8))
        #expect(throws: ChunkedBodyDecoder.ChunkedError.self) {
            _ = try decoder.take(upTo: 4096)
        }
    }

    @Test("the decoder hands back no more than the budget asks for")
    func chunkedRespectsBudget() throws {
        let decoder = ChunkedBodyDecoder()
        decoder.feed(Data("10\r\n0123456789abcdef\r\n0\r\n\r\n".utf8))
        let first = try decoder.take(upTo: 4)
        #expect(String(decoding: first ?? Data(), as: UTF8.self) == "0123")
        let rest = try decoder.take(upTo: 1024)
        #expect(String(decoding: rest ?? Data(), as: UTF8.self) == "456789abcdef")
    }

    // MARK: - Against a real socket

    @Test("one request serves the whole body, and the pull budget is what comes off the wire")
    func onePullRequestServesTheBody() async throws {
        let total: Int64 = 3 * 1024 * 1024
        let origin = try #require(ThrottledOriginServer(totalSize: total, throttleUs: 0))
        defer { origin.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/media.mkv"))

        let delegate = RecordingHeldDelegate(defaultBudget: 128 * 1024)
        let connection = HeldSourceConnection(url: url, offset: 0, extraHeaders: [:],
                                              userAgent: "AetherEngine/test", label: "test",
                                              delegate: delegate)
        connection.start()
        #expect(delegate.waitForEnd(), "the connection never reported an end")

        #expect(delegate.statuses == [206])
        #expect(delegate.endError == nil)
        #expect(Int64(delegate.body.count) == total)
        // The whole point: one range for the whole file, not one per drain cycle.
        #expect(origin.rangeRequestCount == 1)
        #expect(origin.requestedRanges.first?.start == 0)
        #expect(origin.requestedRanges.first?.end == nil, "the held connection asks open-ended")
    }

    @Test("a zero budget ends the connection, and the origin was asked exactly once")
    func zeroBudgetEndsTheConnection() async throws {
        let origin = try #require(ThrottledOriginServer(totalSize: 64 * 1024 * 1024, throttleUs: 0))
        defer { origin.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/media.mkv"))

        // Two pulls, then the answer a paused viewer produces.
        let delegate = RecordingHeldDelegate(budgets: [32 * 1024, 32 * 1024, 0])
        let connection = HeldSourceConnection(url: url, offset: 0, extraHeaders: [:],
                                              userAgent: nil, label: "test", delegate: delegate)
        connection.start()
        #expect(delegate.waitForEnd())

        #expect(delegate.body.count == 64 * 1024)
        #expect(delegate.endError == nil, "a budget of zero is a deliberate end, not a fault")
        #expect(origin.rangeRequestCount == 1)
    }

    @Test("a refused response ends the connection without reading a body")
    func refusedResponseReadsNoBody() async throws {
        // Built outside `#require`: the macro decomposes the call and the scripted response is
        // not a `@Sendable` closure once it has been split into an argument.
        let refusing = ThrottledOriginServer(
            totalSize: 8 * 1024 * 1024, throttleUs: 0,
            respond: { _, _, _ in .status(429, retryAfter: 3) })
        let origin = try #require(refusing)
        defer { origin.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/media.mkv"))

        let delegate = RecordingHeldDelegate()
        let connection = HeldSourceConnection(url: url, offset: 0, extraHeaders: [:],
                                              userAgent: nil, label: "test", delegate: delegate)
        connection.start()
        #expect(delegate.waitForEnd())

        #expect(delegate.statuses == [429], "the refusal has to reach the reader's classification")
        #expect(delegate.body.isEmpty)
    }

    @Test("a redirect is followed and the responding target is the one that served the body")
    func followsRedirect() async throws {
        let total: Int64 = 512 * 1024
        let redirecting = ThrottledOriginServer(totalSize: total, throttleUs: 0, respond: { _, _, path in
            path == "/pinned.mkv" ? .serve206 : .redirect(to: "/pinned.mkv")
        })
        let origin = try #require(redirecting)
        defer { origin.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/source.mkv"))

        let delegate = RecordingHeldDelegate(defaultBudget: 64 * 1024)
        let connection = HeldSourceConnection(url: url, offset: 0, extraHeaders: [:],
                                              userAgent: nil, label: "test", delegate: delegate)
        connection.start()
        #expect(delegate.waitForEnd())

        #expect(delegate.statuses == [206], "only the served response reaches the reader")
        #expect(Int64(delegate.body.count) == total)
        #expect(connection.respondedBy.path == "/pinned.mkv")
        #expect(origin.requestLog.map(\.path) == ["/source.mkv", "/pinned.mkv"])
    }

    @Test("a mid-body offset asks for exactly that offset")
    func offsetIsHonoured() async throws {
        let total: Int64 = 4 * 1024 * 1024
        let origin = try #require(ThrottledOriginServer(totalSize: total, throttleUs: 0))
        defer { origin.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/media.mkv"))

        let offset: Int64 = 1_048_576
        let delegate = RecordingHeldDelegate(defaultBudget: 256 * 1024)
        let connection = HeldSourceConnection(url: url, offset: offset, extraHeaders: [:],
                                              userAgent: nil, label: "test", delegate: delegate)
        connection.start()
        #expect(delegate.waitForEnd())

        #expect(origin.requestedRanges.first?.start == offset)
        #expect(Int64(delegate.body.count) == total - offset)
    }
}
