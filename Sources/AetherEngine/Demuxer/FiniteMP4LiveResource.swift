import Foundation

/// Recognizes finite, non-fragmented MP4 metadata before a live-labelled HTTP reader chooses its IO mode.
/// Uncertain or incomplete metadata keeps the live path; MIME and transfer speed are not evidence.
enum FiniteMP4LiveResource {
    /// A structurally bounded box whose payload may extend beyond the currently received prefix.
    private struct Box {
        /// ISO BMFF box type, used only to recognize container and fragmentation markers.
        let type: String
        /// First payload byte after the normal or extended-size header.
        let payloadStart: Int
        /// Exclusive end within the declared resource, regardless of prefix availability.
        let end: Int
    }

    /// Bounds recursive metadata validation independently of the server's declared resource size.
    private static let maximumContainerDepth = 32

    /// Proves a finite MP4 from a complete file-type box and complete movie metadata without fragments.
    ///
    /// The prefix may end at the movie boundary or within a subsequent `mdat` payload. Every parsed
    /// box must fit `declaredSize`; `moov`, its children and all other inspected boxes must be complete.
    /// No network IO or mutable reader state is touched. A false result means insufficient proof,
    /// including ordinary live TS/HLS, fragmented MP4, malformed sizes and incomplete movie metadata.
    ///
    /// - Parameters:
    ///   - prefix: Bytes received contiguously from the start of the resource.
    ///   - declaredSize: Positive, known total resource length, normally HTTP Content-Length.
    /// - Returns: Whether complete metadata proves the non-fragmented MP4 layout.
    static func isNonFragmentedMP4(prefix: Data, declaredSize: Int64) -> Bool {
        guard declaredSize > 0, prefix.count >= 8, Int64(prefix.count) <= declaredSize else { return false }
        // Live TS appends may inspect a multi-megabyte head repeatedly. Reject its marker before copying.
        let typeStart = prefix.index(prefix.startIndex, offsetBy: 4)
        let typeEnd = prefix.index(prefix.startIndex, offsetBy: 8)
        guard prefix[typeStart..<typeEnd].elementsEqual([0x66, 0x74, 0x79, 0x70]) else { return false }
        // Data slices can retain a nonzero startIndex. Normalize once for bounded offset parsing.
        let bytes = Array(prefix)
        guard
            let fileType = box(in: bytes, at: 0, limit: declaredSize),
            fileType.type == "ftyp",
            fileType.end <= bytes.count,
            validFileType(fileType, in: bytes)
        else { return false }

        var offset = fileType.end
        var foundMovie = false
        while offset < bytes.count {
            guard let current = box(in: bytes, at: offset, limit: declaredSize) else { return false }
            if current.type == "moof" || current.type == "mvex" || current.type == "ftyp" {
                return false
            }
            if current.type == "moov" {
                guard
                    !foundMovie,
                    current.end <= bytes.count,
                    validChildren(of: current, in: bytes, depth: 0)
                else { return false }
                foundMovie = true
            } else if current.end > bytes.count {
                return foundMovie && current.type == "mdat"
            }
            offset = current.end
        }
        return foundMovie
    }

    /// Reads a complete header and rejects zero, undersized, overflowing or out-of-resource boxes.
    private static func box(in bytes: [UInt8], at offset: Int, limit: Int64) -> Box? {
        guard offset >= 0, offset <= bytes.count, bytes.count - offset >= 8 else { return nil }
        let shortSize = unsignedInteger(in: bytes, at: offset, count: 4)
        let headerSize: Int
        let size: UInt64
        if shortSize == 1 {
            guard bytes.count - offset >= 16 else { return nil }
            headerSize = 16
            size = unsignedInteger(in: bytes, at: offset + 8, count: 8)
        } else {
            headerSize = 8
            size = shortSize
        }
        guard
            size >= UInt64(headerSize),
            Int64(offset) <= limit,
            size <= UInt64(limit - Int64(offset)),
            size <= UInt64(Int.max - offset)
        else { return nil }
        let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
        return Box(type: type, payloadStart: offset + headerSize, end: offset + Int(size))
    }

    /// Decodes already-bounded big-endian fields without unaligned native-memory loads.
    private static func unsignedInteger(in bytes: [UInt8], at offset: Int, count: Int) -> UInt64 {
        bytes[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
    }

    /// Requires complete brand fields and an MP4-compatible brand, excluding arbitrary ftyp-like data.
    private static func validFileType(_ fileType: Box, in bytes: [UInt8]) -> Bool {
        let payloadCount = fileType.end - fileType.payloadStart
        guard payloadCount >= 8, payloadCount % 4 == 0 else { return false }
        let brandOffsets = [fileType.payloadStart]
            + Array(stride(from: fileType.payloadStart + 8, to: fileType.end, by: 4))
        var compatible = false
        for offset in brandOffsets {
            let brandBytes = bytes[offset..<(offset + 4)]
            guard brandBytes.allSatisfy({ (0x20...0x7e).contains($0) }) else { return false }
            let brand = String(decoding: brandBytes, as: UTF8.self)
            if ["isom", "mp41", "mp42", "avc1", "M4V ", "M4A ", "dash", "cmfc", "cmfs"].contains(brand)
                || (brand.hasPrefix("iso") && brandBytes.last.map { (0x31...0x39).contains($0) } == true) {
                compatible = true
            }
        }
        return compatible
    }

    /// Validates complete child boundaries in known movie containers and rejects fragment metadata.
    private static func validChildren(of parent: Box, in bytes: [UInt8], depth: Int) -> Bool {
        guard depth < maximumContainerDepth else { return false }
        var offset = parent.payloadStart
        if parent.type == "meta" {
            // ISO meta is a FullBox: its version/flags precede the child box stream.
            guard parent.end - offset >= 4 else { return false }
            offset += 4
        }
        guard offset < parent.end else { return false }
        while offset < parent.end {
            guard
                let child = box(in: bytes, at: offset, limit: Int64(parent.end)),
                child.end <= bytes.count,
                child.type != "mvex",
                child.type != "moof"
            else { return false }
            if ["moov", "trak", "mdia", "minf", "stbl", "edts", "dinf", "udta", "meta"].contains(child.type),
               !validChildren(of: child, in: bytes, depth: depth + 1) {
                return false
            }
            offset = child.end
        }
        return offset == parent.end
    }
}
