import Testing
import Foundation
import CoreMedia
import CoreVideo
import AetherLibavcodec
@testable import AetherEngine

private func makeBuffer(width: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
    return buffer!
}

@Suite("Upscaling frame handler")
struct UpscalingFrameHandlerTests {

    @Test func framesPassThroughTheStageInOrder() {
        let seen = ProbeTestBox<[(Int, Double, Data?)]>([])
        let stagePTS = ProbeTestBox<[Double]>([])
        let handler = UpscalingFrameHandler.wrap({ buf, pts, data in
            seen.update { $0.append((CVPixelBufferGetWidth(buf), pts.seconds, data)) }
        }, upscale: { buf, pts in
            stagePTS.update { $0.append(pts.seconds) }
            return makeBuffer(width: CVPixelBufferGetWidth(buf) * 10)
        })
        let tag = Data([1, 2, 3])
        handler(makeBuffer(width: 16), CMTime(seconds: 1, preferredTimescale: 600), nil)
        handler(makeBuffer(width: 32), CMTime(seconds: 2, preferredTimescale: 600), tag)
        handler(makeBuffer(width: 48), CMTime(seconds: 3, preferredTimescale: 600), nil)
        let got = seen.value
        #expect(got.map(\.0) == [160, 320, 480])
        #expect(got.map(\.1) == [1, 2, 3])
        #expect(got[1].2 == tag)
        #expect(stagePTS.value == [1, 2, 3])
    }

    @Test func nilFromTheStageDeliversTheOriginal() {
        let original = makeBuffer(width: 16)
        let originalID = ObjectIdentifier(original)
        let seen = ProbeTestBox<[Bool]>([])
        let handler = UpscalingFrameHandler.wrap({ buf, _, _ in
            seen.update { $0.append(ObjectIdentifier(buf) == originalID) }
        }, upscale: { _, _ in nil })
        handler(original, .zero, nil)
        #expect(seen.value == [true])
    }

    #if !targetEnvironment(simulator)
    @MainActor
    @Test func hostBuildsTheStageOnlyWithAPlan() throws {
        guard #available(tvOS 26, iOS 26, macOS 26, visionOS 26, *) else { return }
        let host = SoftwarePlaybackHost()
        let noop: DecodedFrameHandler = { _, _, _ in }
        _ = host.upscaledFrameHandler(noop, decoder: SoftwareVideoDecoder(), frameRate: 24)
        #expect(host.frameUpscaler == nil)

        host.upscalePlan = UpscalePlan(
            sourceWidth: 1280, sourceHeight: 720, mlScale: nil, mlOutputWidth: 1280, mlOutputHeight: 720,
            targetWidth: 1920, targetHeight: 1080, displayWidth: 1920, displayHeight: 1080)
        _ = host.upscaledFrameHandler(noop, decoder: SoftwareVideoDecoder(), frameRate: 24)
        #expect(host.frameUpscaler != nil)
        _ = host.upscaledFrameHandler(noop, decoder: SoftwareVideoDecoder(), frameRate: nil)
        #expect(host.frameUpscaler != nil)
    }
    #endif
}
