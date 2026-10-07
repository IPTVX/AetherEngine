import Testing
import Foundation
@testable import AetherEngine

/// End-to-end FEL checks on real Profile 7 files, where the synthetic suites
/// cannot reach: container framing quirks (the Matroska `packet->data != buf->data`
/// case that produced zero frames), real RPUs, real reorder, seeks and teardown.
///
/// The fixtures (`fel-clip-a.mkv`, `fel-clip-b.mkv`, `fel-clip-c.mp4`) live in the
/// directory named by `DV_FEL_TESTS_DIR`, or in `DV FEL Tests/` next to the package;
/// they are not checked in, and every test skips when its file is absent.
struct DoviFelRealFileTests {

    static let fixtures = [
        "fel-clip-a.mkv",
        "fel-clip-b.mkv",
        "fel-clip-c.mp4",
    ]

    static func url(_ name: String) -> URL {
        if let dir = ProcessInfo.processInfo.environment["DV_FEL_TESTS_DIR"] {
            return URL(fileURLWithPath: dir).appendingPathComponent(name)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AetherEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // AetherEngine
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("DV FEL Tests")
            .appendingPathComponent(name)
    }

    static func available(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(name).path)
    }

    /// The `.enabled(if:)` reason of every test that needs a clip: the clips are not checked in, so
    /// those tests show as skipped without them rather than passing without having run.
    static let needsClips: Comment = "needs the DV FEL test clips (not checked in): set DV_FEL_TESTS_DIR"

    /// The fixtures present, for `arguments:` of a test that runs once per clip.
    static var availableFixtures: [String] { fixtures.filter(available) }

    /// The first two clips, when present: the ones long enough to seek into.
    static var firstTwoClips: [String] { [fixtures[0], fixtures[1]].filter(available) }
}
