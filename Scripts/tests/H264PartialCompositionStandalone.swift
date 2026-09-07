import Foundation

@main
struct H264PartialCompositionTests {
    typealias Policy = H264PartialCompositionRepair
    static func main() {
        // Synthetic closed sequence, including a 25 -> 29.97 transition and rounding ticks.
        let times: [Int64] = [0, 3600, 7200, 10800, 14400, 18000, 21600, 25200, 28800, 32400, 36000, 39600, 42603, 45607, 48610]
        let pocs: [Int64] = [0, 8, 2, 4, 6, 16, 10, 12, 14, 24, 18, 20, 22, 28, 26]
        let source = zip(times, pocs).map { Policy.Picture(dts: $0, poc: $1) }
        func repair(_ source: [Policy.Picture], next: Int64 = 51613, lead: Int64 = 6006, confirmed: Bool = false) -> [Int64]? {
            Policy.presentationTimes(source, nextDTS: next, presentationLead: lead, previouslyConfirmed: confirmed)
        }
        let expected = pocs.map { times[Int($0 / 2)] + 6006 }
        precondition(repair(source) == expected)
        precondition(expected.sorted() == times.map { $0 + 6006 })
        let shifted = source.map { Policy.Picture(dts: $0.dts + 63_000_000, poc: $0.poc) }
        precondition(repair(shifted, next: 63_051_613) == expected.map { $0 + 63_000_000 })
        precondition(repair(source, lead: 3000) == nil, "never produce PTS earlier than original DTS")
        precondition(repair(source, lead: 0) == nil)
        precondition(repair(source, next: times.last!) == nil)
        precondition(repair(source, next: Int64.min) == nil)
        precondition(repair(Array(source.prefix(14))) == nil, "truncated POC window")
        for badPOC: Int64 in [-2, 1, 2, 30, Int64.max] {
            var invalid = source; invalid[4] = .init(dts: times[4], poc: badPOC)
            precondition(repair(invalid) == nil)
        }
        var invalid = source; invalid[4] = .init(dts: times[3], poc: pocs[4])
        precondition(repair(invalid) == nil)
        invalid[4] = .init(dts: Int64.min, poc: pocs[4])
        precondition(repair(invalid) == nil)
        let overflow = source.map { Policy.Picture(dts: Int64.max - 51614 + $0.dts, poc: $0.poc) }
        precondition(repair(overflow, next: Int64.max - 1) == nil)
        let ordered = times.enumerated().map { Policy.Picture(dts: $0.element, poc: Int64($0.offset * 2)) }
        precondition(repair(ordered) == nil, "all-zero offsets without reordering are not proof")
        precondition(repair(ordered, confirmed: true) == times.map { $0 + 6006 })
        precondition(repair([.init(dts: 0, poc: 0)]) == nil)
        precondition(repair([.init(dts: 0, poc: 0)], confirmed: true) == [6006])
        precondition(repair([]) == nil)
        let excessive = (0...512).map { Policy.Picture(dts: Int64($0 * 3003), poc: Int64($0 * 2)) }
        precondition(repair(excessive, next: 2_000_000, confirmed: true) == nil)
        print("PASS partial ctts: exact slots, mixed cadence, quantization, seek translation, unchanged decode axis; truncated/field/duplicate POC, insufficient lead, missing/duplicate timestamps, overflow and bounds refused")
    }
}
