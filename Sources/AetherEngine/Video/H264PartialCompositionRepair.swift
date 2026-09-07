import Foundation

/// A mixed MP4 can carry valid ctts at the head and zero offsets in a later IDR sequence.
/// Restore that sequence's display ownership of the ORIGINAL timestamp slots. In particular,
/// a cadence change inside the sequence must not turn into a guessed constant-rate clock.
enum H264PartialCompositionRepair {
    static let maximumPictures = 512
    static let maximumHeldPackets = 1024
    static let maximumHeldBytes = 32 << 20
    struct Picture: Equatable {
        let dts: Int64
        let poc: Int64
    }

    static func presentationTimes(
        _ pictures: [Picture], nextDTS: Int64, presentationLead: Int64,
        previouslyConfirmed: Bool
    ) -> [Int64]? {
        guard (1...maximumPictures).contains(pictures.count), pictures.first?.poc == 0,
              presentationLead > 0, nextDTS != Int64.min else { return nil }
        let slots = pictures.map(\.dts)
        guard slots.allSatisfy({ $0 != Int64.min }) else { return nil }
        for (a, b) in zip(slots, slots.dropFirst() + [nextDTS]) {
            let (step, overflow) = b.subtractingReportingOverflow(a)
            guard !overflow, step > 0 else { return nil }
        }
        var ranks = Set<Int>()
        var reordered = false
        var result: [Int64] = []
        for (index, picture) in pictures.enumerated() {
            // Complete, closed, progressive sequences only. Do not infer missing pictures,
            // fields, open-GOP leading pictures, or parser/POC wraparound.
            guard picture.poc >= 0, picture.poc % 2 == 0,
                  picture.poc / 2 < Int64(pictures.count) else { return nil }
            let rank = Int(picture.poc / 2)
            guard ranks.insert(rank).inserted else { return nil }
            reordered = reordered || rank != index
            let (pts, overflow) = slots[rank].addingReportingOverflow(presentationLead)
            guard !overflow, pts >= picture.dts else { return nil }
            result.append(pts)
        }
        guard reordered || previouslyConfirmed else { return nil }
        return result
    }
}
