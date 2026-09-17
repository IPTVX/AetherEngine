import XCTest
@testable import AetherEngine

/// Protects the legacy and modern seek hold-frame behavior without a live display layer.
final class DisplayFlushOpTests: XCTestCase {
    func testSeekOnModernRendererHoldsDisplayedImage() {
        let op = DisplayFlushOp.resolve(removingDisplayedImage: false, modernRenderer: true)
        XCTAssertEqual(op, .rendererFlush(removingDisplayedImage: false))
    }

    func testSeekOnLegacyRendererHoldsLastFrame() {
        let op = DisplayFlushOp.resolve(removingDisplayedImage: false, modernRenderer: false)
        XCTAssertEqual(op, .holdImage)
    }

    func testStopOnModernRendererRemovesDisplayedImage() {
        let op = DisplayFlushOp.resolve(removingDisplayedImage: true, modernRenderer: true)
        XCTAssertEqual(op, .rendererFlush(removingDisplayedImage: true))
    }

    func testStopOnLegacyRendererRemovesImage() {
        let op = DisplayFlushOp.resolve(removingDisplayedImage: true, modernRenderer: false)
        XCTAssertEqual(op, .removeImage)
    }
}
