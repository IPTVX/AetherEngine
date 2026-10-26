import Foundation
import Testing
@testable import AetherEngine

/// A finite MP4 must be proven by complete container metadata, rather than a MIME or burst-size hint.
@Suite("Finite MP4 live resource classification")
struct FiniteMP4LiveResourceTests {
    /// Builds a bounded ISO BMFF box, including the extended-size header used by large media files.
    private func box(
        _ type: String,
        payload: Data = Data(),
        extended: Bool = false
    ) -> Data {
        var result = integer(extended ? 1 : UInt64(payload.count + 8), bytes: 4)
        result.append(contentsOf: type.utf8)
        if extended {
            result.append(integer(UInt64(payload.count + 16), bytes: 8))
        }
        result.append(payload)
        return result
    }

    /// Encodes unsigned sizes independently of native byte order or alignment.
    private func integer(_ value: UInt64, bytes: Int) -> Data {
        Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    /// A complete file-type header with a major brand, minor version and compatible brand.
    private var fileType: Data {
        box("ftyp", payload: Data("isom".utf8) + integer(0, bytes: 4) + Data("mp42".utf8))
    }

    /// Minimal structurally valid movie metadata; the classifier does not decode movie-header fields.
    private var movie: Data {
        box("moov", payload: box("mvhd", payload: Data(repeating: 0, count: 100)))
    }

    @Test("Complete file metadata identifies a finite resource before its media arrives")
    func metadataAtPrefixBoundaryIsSufficient() {
        let prefix = fileType + movie

        #expect(FiniteMP4LiveResource.isNonFragmentedMP4(prefix: prefix, declaredSize: Int64(prefix.count + 4_096)))
    }

    @Test("A Data slice with a nonzero startIndex retains relative file-type offsets")
    func dataSliceUsesRelativeOffsets() throws {
        let storage = Data(repeating: 0xff, count: 5) + fileType + movie
        let prefix = storage.dropFirst(5)
        try #require(prefix.startIndex > 0)

        #expect(FiniteMP4LiveResource.isNonFragmentedMP4(prefix: prefix, declaredSize: Int64(prefix.count)))
    }

    @Test("A partial mdat payload is safe when its complete header fits the declared file")
    func incompleteMediaPayloadIsAccepted() {
        let media = box("mdat", payload: Data(repeating: 1, count: 64))
        let prefix = fileType + movie + media.prefix(12)

        #expect(FiniteMP4LiveResource.isNonFragmentedMP4(prefix: prefix, declaredSize: Int64(fileType.count + movie.count + media.count)))
    }

    @Test("A real synthetic H.264 MP4 is recognized from its fast-start header")
    func realMP4HeaderIsRecognized() throws {
        let data = try #require(Data(
            base64Encoded: AtmosDetectionProbeIntegrationTests.videoOnlyBase64,
            options: .ignoreUnknownCharacters
        ))
        // The first box is ftyp; the next is the fast-start moov. The fixture's mdat is not needed.
        let fileTypeSize = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        let movieSize = data.dropFirst(fileTypeSize).prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        let prefix = Data(data.prefix(fileTypeSize + movieSize))

        #expect(FiniteMP4LiveResource.isNonFragmentedMP4(prefix: prefix, declaredSize: Int64(data.count)))
    }

    @Test("A complete extended-size movie header remains bounded by the declared length")
    func extendedSizeBoxesAreSupported() {
        let prefix = fileType + box("moov", payload: box("mvhd", payload: Data([0])), extended: true)

        #expect(FiniteMP4LiveResource.isNonFragmentedMP4(prefix: prefix, declaredSize: Int64(prefix.count)))
    }

    @Test("A movie-extends box keeps fragmented MP4 on the live path")
    func movieExtendsIsRejected() {
        let prefix = fileType + box("moov", payload: box("mvhd") + box("mvex", payload: box("trex")))

        #expect(!FiniteMP4LiveResource.isNonFragmentedMP4(prefix: prefix, declaredSize: Int64(prefix.count)))
    }

    @Test("An explicit movie fragment is rejected even after complete movie metadata")
    func movieFragmentIsRejected() {
        let prefix = fileType + movie + box("moof", payload: box("mfhd"))

        #expect(!FiniteMP4LiveResource.isNonFragmentedMP4(prefix: prefix, declaredSize: Int64(prefix.count)))
    }

    @Test(arguments: [Int64(-1), 0, 7, Int64.max])
    func unknownOrInconsistentLengthIsRejected(_ declaredSize: Int64) {
        let prefix = fileType + movie.dropLast()

        #expect(!FiniteMP4LiveResource.isNonFragmentedMP4(prefix: prefix, declaredSize: declaredSize))
    }

    @Test("Neither MIME-like text nor a large TS burst establishes a finite MP4")
    func otherLiveFormatsAreRejected() {
        for prefix in [Data("video/mp4".utf8), TinyTransportStreamFixture.data, Data("#EXTM3U\n#EXTINF:4,\na.ts\n".utf8)] {
            #expect(!FiniteMP4LiveResource.isNonFragmentedMP4(prefix: prefix, declaredSize: Int64(prefix.count)))
        }
    }

    @Test("An incomplete or malformed file-type box supplies no MP4 proof")
    func malformedFileTypesAreRejected() {
        for prefix in [box("ftyp", payload: Data("isom".utf8)) + movie,
                       box("ftyp", payload: Data(repeating: 0, count: 9)) + movie,
                       Data(fileType.dropLast())] {
            #expect(!FiniteMP4LiveResource.isNonFragmentedMP4(prefix: prefix, declaredSize: Int64(prefix.count + 100)))
        }
    }

    @Test("Zero-sized, undersized and overflowing box headers cannot classify a live source")
    func invalidBoxSizesAreRejected() {
        for size in [UInt64(0), 4, UInt64.max, UInt64(Int64.max)] {
            let header = integer(1, bytes: 4) + Data("moov".utf8) + integer(size, bytes: 8)

            #expect(!FiniteMP4LiveResource.isNonFragmentedMP4(prefix: fileType + header, declaredSize: Int64.max))
        }
        let zero = integer(0, bytes: 4) + Data("moov".utf8)
        #expect(!FiniteMP4LiveResource.isNonFragmentedMP4(prefix: fileType + zero, declaredSize: Int64.max))
    }

    @Test("Child boxes must fill the complete movie without crossing its boundary")
    func malformedMovieChildrenAreRejected() {
        let tooLarge = integer(100, bytes: 4) + Data("mvhd".utf8)
        let partialHeader = Data([0, 0, 0, 8])
        for payload in [Data(), tooLarge, box("mvhd") + partialHeader,
                        box("trak", payload: tooLarge)] {
            let prefix = fileType + box("moov", payload: payload)

            #expect(!FiniteMP4LiveResource.isNonFragmentedMP4(prefix: prefix, declaredSize: Int64(prefix.count)))
        }
    }

    @Test("A trailing partial header and media extending beyond Content-Length remain uncertain")
    func trailingUncertaintyIsRejected() {
        let metadata = fileType + movie
        let truncatedHeader = metadata + Data([0, 0, 0, 8])
        let oversizedMedia = metadata + integer(100, bytes: 4) + Data("mdat".utf8)

        #expect(!FiniteMP4LiveResource.isNonFragmentedMP4(prefix: truncatedHeader, declaredSize: Int64(truncatedHeader.count + 100)))
        #expect(!FiniteMP4LiveResource.isNonFragmentedMP4(prefix: oversizedMedia, declaredSize: Int64(oversizedMedia.count + 10)))
    }
}
